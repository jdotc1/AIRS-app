"""Bounded CFG with sequential natural-loop exact-state recovery closure.

The legacy integer/linear auditor is retained separately. Path states are never
joined into invented identities. Uncertain edges overapproximate reachability;
a discrepancy needs a known-reachable witness before it is supported.
"""
from __future__ import annotations

from collections import deque
import struct

from .arm64 import Instruction, MachineState, ModelError, Value, _signed
from .arm64 import decode_instruction as decode_linear
from .audit import MODEL_LIMITATIONS, LEAF_LIMITATION, CALL_LIMITATION, _body_window, _teardown, _recover, encoding_mode
from .types import AuditResult, Evidence, FunctionRange, InputError, Limits, MachOImage, UnwindEntry

MASK32 = (1 << 32) - 1


def decode_instruction(word: int, address: int = 0) -> Instruction:
    if not 0 <= word <= 0xffffffff:
        raise ModelError('invalid_instruction_word','Instruction is not a 32-bit word',address)
    # Field layout adapted from the owned MacScope conditional-compare decoder.
    # Fix reserved bit4/bit10 as well as the register/immediate discriminator.
    form = word & 0xffe00c10
    if form in (0x3a400000,0x3a400800,0x7a400000,0x7a400800,0xba400000,0xba400800,0xfa400000,0xfa400800):
        condition = (word>>12)&15
        if condition not in range(14):
            raise ModelError('cfg_condition_not_modeled','Conditional compare supports EQ through LE (0–13)',address)
        kind = ('x' if word&(1<<31) else 'w')+('ccmp' if word&(1<<30) else 'ccmn')+('_imm' if word&(1<<11) else '_reg')
        return Instruction(address,word,kind,31,(word>>5)&31,(word>>16)&31,immediate=word&15,addressing=str(condition))
    form = word & 0xffe0fc00
    if form in (0x1a000000,0x3a000000,0x5a000000,0x7a000000,0x9a000000,0xba000000,0xda000000,0xfa000000):
        operation = ('adc','adcs','sbc','sbcs')[(word>>29)&3]
        return Instruction(address,word,('x' if word&(1<<31) else 'w')+operation,word&31,(word>>5)&31,(word>>16)&31)
    form = word & 0xff800000
    if form in (0x11000000,0x31000000,0x71000000,0xb1000000,0xf1000000):
        rd,rn = word&31,(word>>5)&31
        if rn == 31 or (form == 0x11000000 and rd == 31):
            raise ModelError('cfg_wsp_not_modeled','Immediate arithmetic using SP/WSP is outside this subset',address)
        immediate = ((word>>10)&0xfff) << (12 if word & (1<<22) else 0)
        return Instruction(address,word,{0x11000000:'wadd',0x31000000:'wadds',0x71000000:'wsubs',0xb1000000:'xadds',0xf1000000:'xsubs'}[form],rd,rn,immediate=immediate)
    form = word & 0xff200000
    if form in (0x2b000000,0x6b000000,0xab000000,0xeb000000):
        shift,amount = (word>>22)&3,(word>>10)&63
        if shift == 3 or (form in (0x2b000000,0x6b000000) and amount >= 32):
            raise ModelError('cfg_shift_not_modeled','Reserved shift or W shift amount outside 0–31',address)
        # Shifted-register encoding, never extended-register. All 31 fields are ZR.
        return Instruction(address,word,{0x2b000000:'wadds_reg',0x6b000000:'wsubs_reg',0xab000000:'xadds_reg',0xeb000000:'xsubs_reg'}[form],word&31,(word>>5)&31,(word>>16)&31,immediate=amount,addressing=('lsl','lsr','asr')[shift])
    form = word & 0xffe00000
    if form in (0x2b200000,0x6b200000,0xab200000,0xeb200000):
        option,amount,rn = (word>>13)&7,(word>>10)&7,(word>>5)&31
        if rn == 31:
            raise ModelError('cfg_extended_sp_not_modeled','Extended arithmetic with SP/WSP source is outside this subset',address)
        if amount > 4 or (form in (0x2b200000,0x6b200000) and option in (3,7)):
            raise ModelError('cfg_extend_not_modeled','Extension/shift is outside the bounded width subset',address)
        return Instruction(address,word,{0x2b200000:'wadds_ext',0x6b200000:'wsubs_ext',0xab200000:'xadds_ext',0xeb200000:'xsubs_ext'}[form],word&31,rn,(word>>16)&31,immediate=amount,addressing=('uxtb','uxth','uxtw','uxtx','sxtb','sxth','sxtw','sxtx')[option])
    # Preserve the existing exact X MOV alias, including original/stack identity.
    if word & 0xffe0ffe0 == 0xaa0003e0:
        return decode_linear(word,address)
    form = word & 0xff000000
    if form in (0x0a000000,0x2a000000,0x4a000000,0x8a000000,0xaa000000,0xca000000):
        amount = (word>>10)&63
        if not word&(1<<31) and amount >= 32:
            raise ModelError('cfg_logical_shift_not_modeled','W logical shift amount is outside 0–31',address)
        operation = (('and','bic'),('orr','orn'),('eor','eon'))[(word>>29)&3][bool(word&(1<<21))]
        return Instruction(address,word,('x' if word&(1<<31) else 'w')+operation+'_reg',word&31,(word>>5)&31,(word>>16)&31,immediate=amount,addressing=('lsl','lsr','asr','ror')[(word>>22)&3])
    form = word & 0xff000000
    if form in (0x6a000000,0xea000000):
        amount = (word>>10)&63
        if form == 0x6a000000 and amount >= 32:
            raise ModelError('cfg_logical_shift_not_modeled','W logical shift amount is outside 0–31',address)
        kind = ('w' if form == 0x6a000000 else 'x')+('bics' if word&(1<<21) else 'ands')
        return Instruction(address,word,kind,word&31,(word>>5)&31,(word>>16)&31,immediate=amount,addressing=('lsl','lsr','asr','ror')[(word>>22)&3])
    form = word & 0xff800000
    if form in (0x12000000,0x32000000,0x52000000,0x72000000,0x92000000,0xb2000000,0xd2000000,0xf2000000):
        width,n,imms,immr = (64 if word&(1<<31) else 32),(word>>22)&1,(word>>10)&63,(word>>16)&63
        length = ((n<<6)|(~imms&63)).bit_length()-1
        if (width == 32 and n) or length < 1:
            raise ModelError('invalid_logical_immediate','Reserved logical-immediate element encoding',address)
        levels = (1<<length)-1
        size,s,r = 1<<length,imms&levels,immr&levels
        if size > width or s == levels:
            raise ModelError('invalid_logical_immediate','Reserved logical-immediate all-ones/width encoding',address)
        element = (1<<(s+1))-1
        element = ((element>>r)|(element<<(size-r)))&((1<<size)-1)
        mask = sum(element<<offset for offset in range(0,width,size))
        operation = ('and','orr','eor','ands')[(word>>29)&3]
        if operation != 'ands' and word&31 == 31:
            raise ModelError('cfg_logical_sp_destination_not_modeled','Nonflag logical-immediate SP/WSP destination is outside this subset',address)
        return Instruction(address,word,('w' if width == 32 else 'x')+operation+'_imm',word&31,(word>>5)&31,immediate=mask)
    # Reuse MacScope high-multiply dispatch; deliberately accept canonical Ra=31 only.
    form = word & 0xffe0fc00
    if form in (0x9b407c00,0x9bc07c00):
        return Instruction(address,word,'umulh' if word&(1<<23) else 'smulh',word&31,(word>>5)&31,(word>>16)&31)
    # Owned MacScope widening op31=001/101; all destinations/accumulators are X.
    form = word & 0xffe08000
    if form in (0x9b200000,0x9b208000,0x9ba00000,0x9ba08000):
        kind=('u' if word&(1<<23) else 's')+('msubl' if word&(1<<15) else 'maddl')
        return Instruction(address,word,kind,word&31,(word>>5)&31,(word>>16)&31,immediate=(word>>10)&31)
    # Owned MacScope three-source op31=000 dispatch; same-width forms.
    form = word & 0xffe08000
    if form in (0x1b000000,0x1b008000,0x9b000000,0x9b008000):
        kind=('x' if word&(1<<31) else 'w')+('msub' if word&(1<<15) else 'madd')
        # immediate stores the Ra register index for this instruction family.
        return Instruction(address,word,kind,word&31,(word>>5)&31,(word>>16)&31,immediate=(word>>10)&31)
    # Owned MacScope two-source dispatch; fix all controls, not just opcode.
    form = word & 0xffe0fc00
    if form in (0x1ac02000,0x1ac02400,0x1ac02800,0x1ac02c00,0x9ac02000,0x9ac02400,0x9ac02800,0x9ac02c00):
        operation=('lslv','lsrv','asrv','rorv')[(word>>10)&3]
        return Instruction(address,word,('x' if word&(1<<31) else 'w')+operation,word&31,(word>>5)&31,(word>>16)&31)
    # Adapt owned MacScope decodeExtract, with exact fixed-bit/width guards.
    if word & 0x1f800000 == 0x13800000:
        form = word & 0xffe00000
        if form not in (0x13800000,0x93c00000):
            raise ModelError('invalid_extract_encoding','Reserved EXTR control bits or N/width combination',address)
        amount=(word>>10)&63
        if form == 0x13800000 and amount >= 32:
            raise ModelError('invalid_extract_encoding','W EXTR shift is outside 0–31',address)
        return Instruction(address,word,'xextr' if word&(1<<31) else 'wextr',word&31,(word>>5)&31,(word>>16)&31,immediate=amount)
    # Adapt owned MacScope bitfield fields/alias split; validate before aliasing.
    if word & 0x1f800000 == 0x13000000:
        form = word & 0xffc00000
        if form not in (0x13000000,0x33000000,0x53000000,0x93400000,0xb3400000,0xd3400000):
            raise ModelError('invalid_bitfield_encoding','Reserved bitfield opcode or N/width combination',address)
        immr,imms = (word>>16)&63,(word>>10)&63
        if not word&(1<<31) and (immr >= 32 or imms >= 32):
            raise ModelError('invalid_bitfield_encoding','W bitfield immediates are outside 0–31',address)
        if form == 0x53000000 and 0 < immr < 32 and imms+1 == immr:
            # Preserve the existing positive W LSL alias and its effects.
            return Instruction(address,word,'wlsl',word&31,(word>>5)&31,immediate=32-immr)
        kind=('x' if word&(1<<31) else 'w')+('sbfm','bfm','ubfm')[(word>>29)&3]
        return Instruction(address,word,kind,word&31,(word>>5)&31,immediate=imms,addressing=str(immr))
    form = word & 0xffc00000
    if form in (0xb9000000,0xb9400000):
        if (word>>5)&31 != 31:
            raise ModelError('cfg_memory_base_not_modeled','W accesses require unsigned offset from SP',address)
        return Instruction(address,word,'wstr' if form == 0xb9000000 else 'wldr',word&31,31,immediate=((word>>10)&0xfff)*4)
    # Reuse owned MacScope op/op2 dispatch, fixing S and reserved bit11.
    form = word & 0xffe00c00
    if form in (0x1a800000,0x1a800400,0x5a800000,0x5a800400,0x9a800000,0x9a800400,0xda800000,0xda800400):
        condition = (word>>12)&15
        if condition not in range(14):
            raise ModelError('cfg_condition_not_modeled','Only condition codes EQ through LE (0–13) are supported',address)
        operation = ('csel','csinc','csinv','csneg')[((word>>30)&1)*2+((word>>10)&1)]
        return Instruction(address,word,('x' if word&(1<<31) else 'w')+operation,word&31,(word>>5)&31,(word>>16)&31,addressing=str(condition))
    if word & 0xfc000000 == 0x14000000:
        return Instruction(address,word,'b',immediate=_signed(word&0x3ffffff,26)*4)
    if word & 0xff000010 == 0x54000000:
        condition = word&15
        if condition not in range(14):
            raise ModelError('cfg_condition_not_modeled','Only condition codes EQ through LE (0–13) are supported',address)
        return Instruction(address,word,'bcond',immediate=_signed((word>>5)&0x7ffff,19)*4,addressing=str(condition))
    return decode_linear(word,address)


class PathState(MachineState):
    def __init__(self, registers=None, sp=None, memory=None, words=None, flags=None, strict_call_state=False):
        self.strict_call_state = strict_call_state
        self.words = dict(words or {})
        self.flags = flags  # N,Z,C,V or None; entry flags are unknown.
        kwargs = {}
        if registers is not None: kwargs['registers']=list(registers)
        if sp is not None: kwargs['sp']=sp
        if memory is not None: kwargs['memory']=dict(memory)
        super().__init__(**kwargs)

    def copy(self) -> PathState:
        return PathState(self.registers,self.sp,self.memory,self.words,self.flags,self.strict_call_state)

    def loop_key(self, certain: bool, path_calls: int) -> tuple:
        """Complete semantic state; private heap/slot indices derive from memory.

        Unknown values retain their descriptions; equality never restores an
        original identity. Only whether a call occurred affects later terminal
        eligibility; the number of identical prior calls does not affect a
        future transfer from this state.
        """
        return (tuple(self.registers), self.sp, tuple(sorted(self.memory.items())),
                tuple(sorted(self.words.items())), self.flags,
                self.strict_call_state, certain, path_calls > 0)

    def read_w(self, register: int) -> Value:
        value = self.read_register(register)
        if self.strict_call_state and value.kind == 'stack':
            raise ModelError('stack_address_truncation_not_modeled','W projection of a derived stack address could hide a call escape')
        return Value('constant',int(value.value)&MASK32) if value.kind == 'constant' else Value('unknown',f'low32 of {value.describe()}')

    def write_w(self, register: int, value: Value) -> None:
        if register != 31:
            # Never reinterpret a truncated original X identity as the full X.
            self._write_register(register,Value('constant',int(value.value)&MASK32) if value.kind == 'constant' else Value('unknown','zero-extended W value with unknown low32'))

    def condition(self, condition: int) -> bool | None:
        if condition not in range(14):
            raise ModelError('cfg_condition_not_modeled','Only condition codes EQ through LE (0–13) are supported')
        if self.flags is None: return None
        n,z,c,v = self.flags
        # Base tests for even condition codes; each odd code is its inverse.
        base=(z,c,n,v,c and not z,n==v,not z and n==v)[condition>>1]
        return not base if condition & 1 else base

    def resume_after_call(self) -> None:
        super().resume_after_call()
        self.flags = None  # NZCV is not preserved by the ABI call summary.

    def _store(self, offset: int, value: Value) -> None:
        for slot in list(self.words):
            if slot < offset+8 and offset < slot+4: del self.words[slot]
        super()._store(offset,value)

    def _set_sp(self, value: Value, address: int) -> None:
        super()._set_sp(value,address)
        self.words = {slot:value for slot,value in self.words.items() if slot >= self.sp.displacement}

    def apply(self, instruction: Instruction) -> None:
        kind,address = instruction.kind,instruction.address
        if kind in ('smulh','umulh'):
            # MacScope highMultiplyOperation captures both incoming X operands.
            left,right=self.read_register(instruction.rn),self.read_register(instruction.rt2)
            if left.kind == 'stack' or right.kind == 'stack':
                raise ModelError('high_multiply_stack_address_not_modeled','High multiply factor is a derived stack address',address)
            value=Value('unknown','Both high multiply factors must be concrete')
            if left.kind == right.kind == 'constant':
                mask=(1<<64)-1
                a,b=int(left.value)&mask,int(right.value)&mask
                if kind == 'smulh': a,b=_signed(a,64),_signed(b,64)
                # Concrete evaluation of the high-multiply intrinsic, without low64 truncation.
                value=Value('constant',((a*b)>>64)&mask)
            self._write_register(instruction.rd,value)
            return
        if kind in ('smaddl','smsubl','umaddl','umsubl'):
            # Check all RAW provenance before projecting factors to W, including leaves.
            raw=tuple(self.read_register(r) for r in (instruction.rn,instruction.rt2,instruction.immediate))
            if any(v.kind == 'stack' for v in raw):
                raise ModelError('widening_multiply_stack_address_not_modeled','Widening multiply factor or accumulator is a derived stack address',address)
            left,right=self.read_w(instruction.rn),self.read_w(instruction.rt2)
            accum=raw[2]
            value=Value('unknown','Both widening factors and accumulator must be concrete')
            if left.kind == right.kind == accum.kind == 'constant':
                # MacScope widenedWordValue: truncate to32 before signed/unsigned widen.
                a,b=int(left.value),int(right.value)
                if kind.startswith('s'): a,b=_signed(a,32),_signed(b,32)
                product=a*b
                addend=int(accum.value)&((1<<64)-1)
                # MacScope longMultiplyAccumulateOperation preserves accumulator order.
                result=addend-product if kind.endswith('msubl') else addend+product
                value=Value('constant',result&((1<<64)-1))
            self._write_register(instruction.rd,value)
            return
        if kind in ('wmadd','wmsub','xmadd','xmsub'):
            wide=kind.startswith('x')
            # MacScope multiplyAccumulateOperation reads every old source first.
            read=self.read_register if wide else self.read_w
            left,right,accum=(read(r) for r in (instruction.rn,instruction.rt2,instruction.immediate))
            if wide and any(v.kind == 'stack' for v in (left,right,accum)):
                raise ModelError('multiply_stack_address_not_modeled','Multiply factor or accumulator is a derived stack address',address)
            value=Value('unknown','Both multiply factors and accumulator must be concrete')
            if left.kind == right.kind == accum.kind == 'constant':
                mask=(1<<(64 if wide else 32))-1
                product=(int(left.value)&mask)*(int(right.value)&mask)
                addend=int(accum.value)&mask
                result=addend-product if kind.endswith('msub') else addend+product
                value=Value('constant',result&mask)
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wlslv','wlsrv','wasrv','wrorv','xlslv','xlsrv','xasrv','xrorv'):
            wide=kind.startswith('x')
            source=self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            count=self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2)
            if wide and (source.kind == 'stack' or count.kind == 'stack'):
                raise ModelError('variable_shift_stack_address_not_modeled','Variable-shift value or count is a derived stack address',address)
            value=Value('unknown','Variable-shift value and count must both be concrete')
            if source.kind == count.kind == 'constant':
                width=64 if wide else 32
                mask=(1<<width)-1
                operand=int(source.value)&mask
                # Adapt MacScope shiftAmountModWidth, shiftOperand and rotateRightOperation.
                amount=int(count.value)&(width-1)
                operation=kind[1:]
                if operation == 'lslv': result=operand<<amount
                elif operation == 'lsrv': result=operand>>amount
                elif operation == 'asrv': result=_signed(operand,width)>>amount
                else: result=operand if amount==0 else (operand>>amount)|(operand<<(width-amount))
                value=Value('constant',result&mask)
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wextr','xextr'):
            wide=kind.startswith('x')
            high=self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            low=self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2)
            if wide and (high.kind == 'stack' or low.kind == 'stack'):
                raise ModelError('extract_stack_address_not_modeled','EXTR source is a derived stack address',address)
            value=Value('unknown','Both EXTR sources must be concrete even for shift zero')
            if high.kind == low.kind == 'constant':
                width=64 if wide else 32
                mask=(1<<width)-1
                upper,lower=int(high.value)&mask,int(low.value)&mask
                amount=instruction.immediate
                # MacScope extractRegisterPairOperation / rotateRightOperation.
                result=lower if amount==0 else (lower>>amount)|(upper<<(width-amount))
                value=Value('constant',result&mask)
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wsbfm','wbfm','wubfm','xsbfm','xbfm','xubfm'):
            wide = kind.startswith('x')
            merge = kind in ('wbfm','xbfm')
            source = self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            old = (self.read_register(instruction.rd) if wide else self.read_w(instruction.rd)) if merge else Value('constant',0)
            if wide and (source.kind == 'stack' or old.kind == 'stack'):
                raise ModelError('bitfield_stack_address_not_modeled','Bitfield source or merge destination is a derived stack address',address)
            value=Value('unknown','Bitfield source or required old destination is not concrete')
            if source.kind == old.kind == 'constant':
                width=64 if wide else 32
                mask=(1<<width)-1
                r,s=int(instruction.addressing),instruction.immediate
                # MacScope extract / insert-zero / insert / extract-insert-low.
                source_lsb,destination_lsb,bits=(r,0,s-r+1) if s>=r else (0,width-r,s+1)
                field_mask=(1<<bits)-1
                field=(int(source.value)&mask)>>source_lsb&field_mask
                if kind in ('wsbfm','xsbfm') and field&(1<<(bits-1)): field-=1<<bits
                result=field<<destination_lsb
                if merge:
                    insert_mask=field_mask<<destination_lsb
                    result=(int(old.value)&mask&~insert_mask)|result
                value=Value('constant',result&mask)
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wccmp_reg','wccmp_imm','wccmn_reg','wccmn_imm','xccmp_reg','xccmp_imm','xccmn_reg','xccmn_imm'):
            predicate = self.condition(int(instruction.addressing))
            if predicate is False:
                self.flags=tuple(bool(instruction.immediate&bit) for bit in (8,4,2,1))
                return
            wide = kind.startswith('x')
            left_value = self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            right_value = Value('constant',instruction.rt2) if kind.endswith('_imm') else (self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2))
            if wide and (left_value.kind == 'stack' or right_value.kind == 'stack'):
                raise ModelError('conditional_compare_stack_address_not_modeled','Possible conditional comparison on derived stack addresses is outside this subset',address)
            self.flags = None
            if predicate is True and left_value.kind == right_value.kind == 'constant':
                width = 64 if wide else 32
                mask,sign = (1<<width)-1,1<<(width-1)
                left,right = int(left_value.value)&mask,int(right_value.value)&mask
                subtract = kind in ('wccmp_reg','wccmp_imm','xccmp_reg','xccmp_imm')
                if subtract: right=(~right)&mask
                carry = int(subtract)
                total = left+right+carry
                result = total&mask
                signed_total = (left-(mask+1) if left&sign else left)+(right-(mask+1) if right&sign else right)+carry
                self.flags=(bool(result&sign),result==0,total>mask,not -sign<=signed_total<sign)
            return
        if kind in ('wadc','wadcs','wsbc','wsbcs','xadc','xadcs','xsbc','xsbcs'):
            wide = kind.startswith('x')
            left_value = self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            right_value = self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2)
            if wide and (left_value.kind == 'stack' or right_value.kind == 'stack'):
                raise ModelError('carry_stack_address_not_modeled','Carry arithmetic on derived stack addresses is outside this subset',address)
            carry = None if self.flags is None else int(self.flags[2])
            sets_flags = kind in ('wadcs','wsbcs','xadcs','xsbcs')
            value = Value('unknown','Carry input or operands are not concrete width-bounded values')
            if sets_flags: self.flags = None
            if carry is not None and left_value.kind == right_value.kind == 'constant':
                width = 64 if wide else 32
                mask,sign = (1<<width)-1,1<<(width-1)
                left,right = int(left_value.value)&mask,int(right_value.value)&mask
                if kind in ('wsbc','wsbcs','xsbc','xsbcs'): right=(~right)&mask
                total = left+right+carry
                result = total&mask
                signed_total = (left-(mask+1) if left&sign else left)+(right-(mask+1) if right&sign else right)+carry
                value = Value('constant',result)
                if sets_flags: self.flags=(bool(result&sign),result==0,total>mask,not -sign<=signed_total<sign)
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wadd','wadds','wsubs','wlsl','xadds','xsubs','wadds_reg','wsubs_reg','xadds_reg','xsubs_reg','wadds_ext','wsubs_ext','xadds_ext','xsubs_ext'):
            arithmetic_kind = kind.removesuffix('_reg').removesuffix('_ext')
            wide = kind.startswith('x')
            source = self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            operand = (self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2)) if kind.endswith(('_reg','_ext')) else Value('constant',instruction.immediate)
            if wide and (source.kind == 'stack' or operand.kind == 'stack'):
                raise ModelError('flag_stack_address_not_modeled','Flag arithmetic on a derived stack address is outside this subset',address)
            mask = (1 << (64 if wide else 32)) - 1
            sign = (mask + 1) >> 1
            produces_flags = arithmetic_kind in ('wadds','wsubs','xadds','xsubs')
            value = Value('unknown','Arithmetic operand is not a concrete width-bounded value')
            if source.kind == operand.kind == 'constant':
                left,right = int(source.value)&mask,int(operand.value)&mask
                if kind.endswith('_ext'):
                    bits = {'uxtb':8,'uxth':16,'uxtw':32,'uxtx':64,'sxtb':8,'sxth':16,'sxtw':32,'sxtx':64}[instruction.addressing]
                    right &= (1<<bits)-1
                    if instruction.addressing.startswith('s') and right & (1<<(bits-1)): right -= 1<<bits
                    right = (right<<instruction.immediate)&mask
                elif kind.endswith('_reg'):
                    amount = instruction.immediate
                    if instruction.addressing == 'lsl': right=(right<<amount)&mask
                    elif instruction.addressing == 'lsr': right>>=amount
                    else: right=((right-(mask+1) if right&sign else right)>>amount)&mask
                if kind == 'wlsl': result=(left<<instruction.immediate)&mask
                elif arithmetic_kind in ('wsubs','xsubs'):
                    result=(left-right)&mask
                    self.flags=(bool(result&sign),result==0,left>=right,bool((left^right)&(left^result)&sign))
                else:
                    result=(left+right)&mask
                    if produces_flags:
                        self.flags=(bool(result&sign),result==0,left+right>mask,bool(~(left^right)&(left^result)&sign))
                value=Value('constant',result)
            elif produces_flags: self.flags=None
            if wide:
                if instruction.rd != 31: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wands','wbics','xands','xbics','wands_imm','xands_imm','wand_imm','worr_imm','weor_imm','xand_imm','xorr_imm','xeor_imm','wand_reg','wbic_reg','worr_reg','worn_reg','weor_reg','weon_reg','xand_reg','xbic_reg','xorr_reg','xorn_reg','xeor_reg','xeon_reg'):
            sets_flags = kind in ('wands','wbics','xands','xbics','wands_imm','xands_imm')
            wide = kind.startswith('x')
            left_value = self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            right_value = Value('constant',instruction.immediate) if kind.endswith('_imm') else (self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2))
            if wide and (left_value.kind == 'stack' or right_value.kind == 'stack'):
                raise ModelError('logical_stack_address_not_modeled','Logical operations on derived stack addresses are outside this subset',address)
            value = Value('unknown','Logical operands are not both concrete width-bounded values')
            if sets_flags: self.flags = None
            if left_value.kind == right_value.kind == 'constant':
                width = 64 if wide else 32
                mask,sign = (1<<width)-1,1<<(width-1)
                left,right = int(left_value.value)&mask,int(right_value.value)&mask
                if not kind.endswith('_imm'):
                    amount = instruction.immediate
                    if instruction.addressing == 'lsl': right=(right<<amount)&mask
                    elif instruction.addressing == 'lsr': right>>=amount
                    elif instruction.addressing == 'asr': right=((right-(mask+1) if right&sign else right)>>amount)&mask
                    else: right=((right>>amount)|(right<<(width-amount)))&mask
                if kind in ('wbics','xbics','wbic_reg','xbic_reg','worn_reg','xorn_reg','weon_reg','xeon_reg'): right=(~right)&mask
                if kind in ('worr_imm','xorr_imm','worr_reg','xorr_reg','worn_reg','xorn_reg'): result=left|right
                elif kind in ('weor_imm','xeor_imm','weor_reg','xeor_reg','weon_reg','xeon_reg'): result=left^right
                else: result=left&right
                value = Value('constant',result)
                if sets_flags: self.flags = (bool(result&sign),result==0,False,False)
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wcsel','wcsinc','wcsinv','wcsneg','xcsel','xcsinc','xcsinv','xcsneg'):
            wide = kind.startswith('x')
            left = self.read_register(instruction.rn) if wide else self.read_w(instruction.rn)
            right = self.read_register(instruction.rt2) if wide else self.read_w(instruction.rt2)
            if wide and (left.kind == 'stack' or right.kind == 'stack'):
                raise ModelError('conditional_select_stack_address_not_modeled','Conditional select on derived stack addresses is outside this subset',address)
            mask=(1<<(64 if wide else 32))-1
            if left.kind == 'constant': left=Value('constant',int(left.value)&mask)
            if right.kind == 'constant': right=Value('constant',int(right.value)&mask)
            condition=self.condition(int(instruction.addressing))
            # MacScope conditionalSelectFalseValue: increment, invert or negate
            # only the false arm. AIRS keeps width and recovery identity explicit.
            operation=kind[1:]
            if operation != 'csel':
                if right.kind == 'constant':
                    mask=(1<<(64 if wide else 32))-1
                    raw=int(right.value)&mask
                    transformed=raw+1 if operation=='csinc' else (~raw if operation=='csinv' else -raw)
                    right=Value('constant',transformed&mask)
                else: right=Value('unknown','Conditional-select transformed operand is not concrete')
            value=(left if condition else right) if condition is not None else (left if left==right else Value('unknown','Conditional select alternatives differ under unknown flags'))
            if wide: self._write_register(instruction.rd,value)
            else: self.write_w(instruction.rd,value)
            return
        if kind in ('wstr','wldr'):
            if self.sp.kind != 'stack':
                raise ModelError('unknown_memory_address','SP does not identify a known stack frame',address)
            offset=self.sp.displacement+instruction.immediate
            if offset%4 or offset<self.sp.displacement or offset+4>0:
                raise ModelError('memory_outside_modeled_frame','W memory access is outside the allocated stack frame',address)
            if kind == 'wstr':
                for slot in list(self.memory):
                    if slot < offset+4 and offset < slot+8:
                        if self.strict_call_state and self.memory[slot].kind == 'stack':
                            raise ModelError('partial_stack_address_not_modeled','Partial store into a derived stack address could hide a call escape',address)
                        super()._store(slot,Value('unknown','saved 64-bit value overwritten by a W store'))
                self.words[offset]=self.read_w(instruction.rd)
            else:
                if offset in self.words: value=self.words[offset]
                else:
                    slot=offset-offset%8
                    if slot not in self.memory:
                        raise ModelError('unknown_stack_read','W load has no modeled prior store',address)
                    saved=self.memory[slot]
                    if self.strict_call_state and saved.kind == 'stack':
                        raise ModelError('stack_address_truncation_not_modeled','W load projects a derived stack address',address)
                    value=(Value('constant',(int(saved.value)>>((offset-slot)*8))&MASK32) if saved.kind == 'constant'
                           else Value('unknown','low32 from a modeled 64-bit store'))
                self.write_w(instruction.rd,value)
            return
        if kind in ('b','bcond'):
            raise ModelError('cfg_edge_requires_dispatch','Branches require CFG successor dispatch',address)
        super().apply(instruction)


def _natural_loops(instructions, targets, body_indices):
    """Adapt MacScope dominance/backedge and predecessor-closure algorithms.

    At most two disjoint, ordered backward conditional edges. Removing them
    leaves only forward edges, hence an acyclic residual graph. Dominance is
    checked by reachability with each header removed.
    """
    backward=[(source,target) for source,target in targets.items() if target<=source]
    if not backward:
        return {}
    if len(backward)>2:
        raise ModelError('cfg_loop_shape_not_modeled','At most two sequential natural-loop backedges are supported',instructions[backward[2][0]].address)
    successors={index: (() if ins.kind=='ret' else
                       (targets[index],) if ins.kind=='b' else
                       (targets[index],index+1) if ins.kind=='bcond' else
                       (index+1,)) for index,ins in enumerate(instructions)}
    predecessors={index:set() for index in successors}
    for index,edges in successors.items():
        for target in edges:
            if target in predecessors:predecessors[target].add(index)
    loops={}
    for source,header in sorted(backward,key=lambda edge:edge[1]):
        if (header>=source or instructions[source].kind!='bcond'
                or source not in body_indices or header not in body_indices):
            raise ModelError('cfg_loop_shape_not_modeled','Only non-self conditional body backedges are supported',instructions[source].address)
        # A path to the latch that avoids the header disproves dominance.
        work=[0];reachable=set()
        while work:
            index=work.pop()
            if index==header or index in reachable or index not in successors:continue
            reachable.add(index);work.extend(successors[index])
        if source in reachable:
            raise ModelError('cfg_loop_shape_not_modeled','Loop header must dominate its latch; multiple-entry cycles decline',instructions[source].address)
        # Same natural-loop predecessor walk as MacScope ScalarCFGStatePlan.
        members={header,source};work=[source]
        while work:
            index=work.pop()
            if index==header:continue
            for predecessor in predecessors[index]:
                if predecessor not in members:
                    members.add(predecessor);work.append(predecessor)
        if not members<=body_indices:
            raise ModelError('cfg_loop_shape_not_modeled','Loop cannot include setup or a return teardown',instructions[source].address)
        if header in loops:
            raise ModelError('cfg_loop_shape_not_modeled','Multiple latches for one header are outside this subset',instructions[source].address)
        loops[header]=frozenset(members)
    if len(loops)==2:
        (first,first_members),(second,second_members)=loops.items()
        if max(first_members)>=second or first_members&second_members:
            raise ModelError('cfg_loop_shape_not_modeled','Nested, overlapping or interleaved loops are outside this subset',instructions[second].address)
    return loops


def audit_cfg_function(image: MachOImage, function: FunctionRange, entry: UnwindEntry | None,
                       limits: Limits = Limits(), *, allow_calls: bool = False, cfi_table=None) -> AuditResult:
    mode=encoding_mode(entry.encoding) if entry else 'none'
    coverage='dwarf_reference' if mode=='dwarf' else ('compact' if entry else 'none')
    steps=0; count=0; fde=None
    scope='synchronous_call_sites' if allow_calls else 'modeled_leaf_body'
    limitations=MODEL_LIMITATIONS+((CALL_LIMITATION if allow_calls else LEAF_LIMITATION),
        ('Only forward compact-frame paths with shared setup and independently checked return regions with bounded forward EQ–LE or unconditional suffix transfers and direct calls to independent function entries are modeled; no CFI CFG extension.' if allow_calls else 'Only forward acyclic compact-frameless leaf paths with independently checked return stack regions with bounded forward EQ–LE or unconditional suffix transfers are modeled; no calls or CFI CFG extension.'),
        'Unknown supported NZCV conditions explore both successors without merging identities; possible-only discrepancies remain unresolved.')

    def unresolved(code: str, message: str, address=None, scope='metadata_only') -> AuditResult:
        return AuditResult('unresolved',coverage,mode,scope,(code,),evidence=(Evidence(code,message,address),)[:limits.max_evidence_per_function],limitations=limitations,instruction_count=count,cfg_steps=steps)

    if entry is None:
        return unresolved('missing_unwind_metadata','A present nonzero compact rule is required')
    if entry.encoding == 0:
        coverage='none'
        return unresolved('empty_unwind_rule','The metadata explicitly contains no compact rule')
    if image.architecture!='arm64' or image.cpu_subtype not in (0,1):
        return unresolved('unsupported_cfg_architecture','CFG checking requires an exact ordinary ARM64 subtype')
    if function.boundary_source!='lc_function_starts':
        return unresolved('untrusted_function_boundary','CFG checking needs an independent complete code-only function')
    if not entry.start<=function.start<function.end<=entry.end:
        return unresolved('metadata_range_incomplete','One metadata rule must cover the entire function')
    if mode=='dwarf' and allow_calls:
        from .dwarf_cfi import parse_eh_frame
        try:
            if isinstance(cfi_table,InputError): raise cfi_table
            if not 0<=entry.encoding<=0xffffffff or entry.encoding & ~0xffffffff:
                raise InputError('dwarf_cfi_unsupported','DWARF encoding contains unsupported flags')
            table=cfi_table if cfi_table is not None else parse_eh_frame(image,limits)
            fde=table.select(entry.encoding & 0xffffff,function)
        except InputError as error:
            return unresolved(error.code,str(error))
        coverage='dwarf_evaluated'
        limitations=MODEL_LIMITATIONS+(CALL_LIMITATION,
            'Only bounded forward paths with shared setup and independently checked return regions with bounded forward EQ–LE or unconditional suffix transfers and direct calls to independent function entries are modeled; CFI rows apply at original BL PCs.',
            'Unknown supported NZCV conditions explore both successors without merging identities; possible-only discrepancies remain unresolved.')
    allowed=0xff00001f if allow_calls else 0xfffff000
    required_mode='frame' if allow_calls else 'frameless'
    if fde is None and (mode!=required_mode or not 0<=entry.encoding<=0xffffffff or entry.encoding & ~allowed):
        return unresolved('cfg_metadata_not_modeled','CFG metadata is outside the bounded integer frame/leaf subset')
    try:
        if function.start%4 or function.size%4 or function.size==0:
            raise ModelError('unaligned_function_range','CFG range must be nonempty and instruction-aligned',function.start)
        if function.size>limits.max_instructions_per_function*4:
            raise ModelError('function_instruction_limit','CFG function exceeds the instruction limit',function.start)
        instructions=tuple(decode_instruction(word,function.start+index*4) for index,(word,) in enumerate(struct.iter_unpack('<I',image.bytes_at(function.start,function.size))))
        count=len(instructions)
        returns=[index for index,ins in enumerate(instructions) if ins.kind=='ret']
        if not returns or any(ins.kind!='nop' for ins in instructions[returns[-1]+1:]):
            raise ModelError('cfg_return_shape_not_modeled','RET x30 terminals and only NOP tail are supported',function.start)
        first=instructions[0]
        body_start=0
        regions=[]; leaf_totals=[]
        if allow_calls:
            body_start,_=_body_window(instructions,returns[0])
        for ret in returns:
            if allow_calls:
                end=ret
                lower=regions[-1][1]+1 if regions else body_start
                for index in range(ret-1,lower-1,-1):
                    if _teardown(instructions[index]): end=index
                    elif instructions[index].kind!='nop': break
            elif first.kind=='sub' and first.rd==first.rn==31 and first.immediate>0:
                body_start=1;end=ret;total=0
                lower=regions[-1][1]+1 if regions else body_start
                for index in range(ret-1,lower-1,-1):
                    teardown=instructions[index]
                    if teardown.kind=='add' and teardown.rd==teardown.rn==31 and teardown.immediate>0:
                        end=index;total+=teardown.immediate
                    elif teardown.kind!='nop': break
                leaf_totals.append(total)
            else: end=ret
            if end<body_start or (regions and end<=regions[-1][1]):
                raise ModelError('cfg_return_shape_not_modeled','Return teardown regions overlap setup or each other',instructions[ret].address)
            regions.append((end,ret))
        signatures={tuple(ins.word for ins in instructions[start:ret+1]) for start,ret in regions}
        teardown_indices={index for start,ret in regions for index in range(start,ret+1)}
        teardown_starts={start for start,_ in regions}
        shared_edges={}
        # A prefix transfer is recognized only after its forward destination has
        # already been classified. Reverse order supports chains without rescans.
        for index in range(returns[-1]-1,body_start-1,-1):
            ins=instructions[index]
            if ins.kind not in ('b','bcond'): continue
            target=ins.address+ins.immediate
            target_index=(target-function.start)//4
            if target%4 or target<=ins.address or target_index not in teardown_indices: continue
            if ins.kind=='bcond' and index+1 not in teardown_indices: continue
            start=index
            for previous in range(index-1,body_start-1,-1):
                part=instructions[previous]
                restore=(_teardown(part) if allow_calls else
                         part.kind=='add' and part.rd==part.rn==31 and part.immediate>0)
                if previous in teardown_indices: break
                if restore: start=previous
                elif part.kind!='nop': break
            if start==index: continue  # An ordinary body branch gains no interior entry.
            shared_edges[index]=target_index
            teardown_indices.update(range(start,index+1))
            teardown_starts.add(start)
        if leaf_totals:
            if not shared_edges and any(total!=first.immediate for total in leaf_totals):
                raise ModelError('cfg_return_shape_not_modeled','Each leaf teardown must exactly deallocate the entry allocation',function.start)
            if shared_edges:
                remaining={}
                for index in sorted(teardown_indices,reverse=True):
                    ins=instructions[index]
                    if ins.kind=='ret': remaining[index]=(0,0)
                    elif index in shared_edges:
                        low,high=remaining[shared_edges[index]]
                        if ins.kind=='bcond':
                            other_low,other_high=remaining[index+1]
                            low,high=min(low,other_low),max(high,other_high)
                        remaining[index]=(low,high)
                    else:
                        amount=ins.immediate if ins.kind=='add' else 0
                        low,high=remaining[index+1]
                        remaining[index]=(low+amount,high+amount)
                # A partial suffix can be entered only by a classified prefix;
                # body entry still requires the full entry allocation's pop.
                teardown_starts={index for index in teardown_starts if remaining[index]==(first.immediate,first.immediate)}
        body_indices=set(range(body_start,returns[-1]))-teardown_indices
        if not body_indices:
            raise ModelError('no_supported_observation','No distinct CFG body state exists',function.start)
        targets={}
        call_targets={}
        callee_entries={fn.start for fn in image.functions if fn.boundary_source=='lc_function_starts' and fn.start!=function.start}
        for index,ins in enumerate(instructions):
            if ins.kind=='bl':
                if not allow_calls:
                    raise ModelError('cfg_calls_not_modeled','CFG calls are outside the bounded leaf subset',ins.address)
                target=ins.address+ins.immediate
                if index not in body_indices:
                    raise ModelError('cfg_call_outside_body','A direct call is outside the shared frame body',ins.address)
                call_targets[index]=target
            if index in body_indices and (ins.changes_sp or ins.changes_fp or (ins.kind in ('wadc','wadcs','wsbc','wsbcs','xadc','xadcs','xsbc','xsbcs','wadd','wadds','wsubs','xadds','xsubs','wadds_reg','wsubs_reg','xadds_reg','xsubs_reg','wadds_ext','wsubs_ext','xadds_ext','xsubs_ext','smulh','umulh','smaddl','smsubl','umaddl','umsubl','wmadd','wmsub','xmadd','xmsub','wlslv','wlsrv','wasrv','wrorv','xlslv','xlsrv','xasrv','xrorv','wextr','xextr','wsbfm','wbfm','wubfm','xsbfm','xbfm','xubfm','wlsl','wcsel','wcsinc','wcsinv','wcsneg','xcsel','xcsinc','xcsinv','xcsneg','wldr','wands','wbics','xands','xbics','wands_imm','xands_imm','wand_imm','worr_imm','weor_imm','xand_imm','xorr_imm','xeor_imm','wand_reg','wbic_reg','worr_reg','worn_reg','weor_reg','weon_reg','xand_reg','xbic_reg','xorr_reg','xorn_reg','xeor_reg','xeon_reg') and ins.rd==29)):
                raise ModelError('cfg_frame_transition_not_modeled','Frame transitions inside CFG body are not supported',ins.address)
            if ins.kind in ('b','bcond'):
                target=ins.address+ins.immediate
                target_index=(target-function.start)//4
                if (target%4 or not 0<=target_index<len(instructions) or (index not in body_indices and index not in shared_edges)
                        or (shared_edges.get(index)!=target_index and target_index not in body_indices and target_index not in teardown_starts)):
                    raise ModelError('cfg_edge_not_modeled','Branch must target the body/shared teardown in this function',ins.address)
                targets[index]=target_index
        loops=_natural_loops(instructions,targets,body_indices)
        loop_members=frozenset().union(*loops.values()) if loops else frozenset()
        if not allow_calls and any(instructions[index].kind=='bl' for index in loop_members):
            raise ModelError('cfg_loop_call_not_modeled','Calls inside a leaf loop are outside this subset',instructions[next(iter(loops))].address)
        for index,target in call_targets.items():
            if not 0<=target<1<<64 or function.start<=target<function.end or target not in callee_entries:
                raise ModelError('cfg_call_target_not_modeled','BL must target a distinct independently known function entry',instructions[index].address)
        if loops:
            limitations=tuple(item for item in limitations if not item.startswith(('Only forward','Only bounded forward')))+(
                'One or two sequential, disjoint natural loops with conditional backedges and stable body SP/FP are modeled; direct calls use the bounded owned-target ABI summary. Exact full-state recurrence closes safety exploration; termination and function-output correctness are not established.',
                'Distinct header-qualified loop states are explored separately, bounded by max_cfg_paths_per_function per path across all headers; exhaustion remains unresolved.')
        loop_closures=0;loop_visits=0
        if limits.max_cfg_paths_per_function<1:
            raise ModelError('cfg_path_limit','CFG initial path exceeds the path budget',function.start)
        queue=deque([(0,PathState(strict_call_state=allow_calls),True,0,frozenset())])
        created_paths=1; terminals=0; speculative_terminals=0; no_call_terminals=0; observations=[]; call_evidence=[]; cfi_evidence=[]
        while queue:
            index,state,certain,path_calls,loop_seen=queue.popleft()
            while True:
                if steps>=limits.max_cfg_steps_per_function:
                    raise ModelError('cfg_work_limit','CFG state-visit budget exhausted',instructions[index].address)
                steps+=1
                ins=instructions[index]
                if index in loops:
                    key=(index,state.loop_key(certain,path_calls))
                    if key in loop_seen:
                        loop_closures+=1
                        break
                    if len(loop_seen)>=limits.max_cfg_paths_per_function:
                        raise ModelError('cfg_loop_state_limit','Distinct loop-header state budget exhausted',ins.address)
                    loop_seen=loop_seen|{key}
                    loop_visits+=1
                if not allow_calls and index in body_indices:
                    if len(observations)>=limits.max_observations_per_function:
                        raise ModelError('observation_limit','CFG path-state observations exceed the limit',ins.address)
                    observations.append((ins.address,_recover(state,entry.encoding,'frameless'),certain))
                if ins.kind=='ret':
                    expected={'SP':Value('stack'),**{f'x{reg}':Value('original',reg) for reg in range(19,31)}}
                    actual={'SP':state.sp,**{f'x{reg}':state.registers[reg] for reg in range(19,31)}}
                    if actual!=expected:
                        raise ModelError('unmodeled_return_state','A conservative CFG return does not restore all caller identities',ins.address)
                    terminals+=1;speculative_terminals+=not certain
                    no_call_terminals+=path_calls==0
                    break
                if ins.kind=='b': index=targets[index];continue
                if ins.kind=='bcond':
                    condition=state.condition(int(ins.addressing))
                    if condition is None:
                        if created_paths>=limits.max_cfg_paths_per_function:
                            raise ModelError('cfg_path_limit','CFG created-path budget exhausted',ins.address)
                        created_paths+=1
                        queue.append((targets[index],state.copy(),False,path_calls,loop_seen))
                        certain=False;index+=1
                    else: index=targets[index] if condition else index+1
                    continue
                state.apply(ins)
                if ins.kind=='bl':
                    if len(observations)>=limits.max_observations_per_function:
                        raise ModelError('observation_limit','CFG call-state observations exceed the limit',ins.address)
                    if fde is not None:
                        row=fde.row_at(ins.address)
                        recovered=row.recover(state)
                        if len(cfi_evidence)<limits.max_evidence_per_function:
                            cfi_evidence.append(Evidence('dwarf_cfi_row',f'FDE __eh_frame+{fde.offset:#x}, CIE +{fde.cie_offset:#x}, row at {row.pc:#x}',
                                                         ins.address,'entry SP and original x19–x30',row.describe()))
                    else: recovered=_recover(state,entry.encoding,'frame')
                    observations.append((ins.address,recovered,certain))
                    if len(call_evidence)<limits.max_evidence_per_function:
                        call_evidence.append(Evidence('cfg_call_site',f'BL suspension at {ins.address:#x}, target {call_targets[index]:#x}; callee ABI summary only, not analyzed',
                                                      ins.address,Value('constant',ins.address+4).describe(),state.registers[30].describe()))
                    path_calls+=1
                    state.resume_after_call()
                index+=1
    except ModelError as error:
        return unresolved(error.code,str(error),error.address)
    expected={'SP':Value('stack'),**{f'x{reg}':Value('original',reg) for reg in range(19,31)}}
    mismatches=[];mismatch_count=0;known_witness=False;unknown_count=0
    for pc,recovered,certain in observations:
        for register,want in expected.items():
            got=recovered[register]
            if not got.known:unknown_count+=1
            elif got!=want:
                mismatch_count+=1;known_witness|=certain
                if len(mismatches)<limits.max_evidence_per_function:
                    mismatches.append(Evidence('caller_state_mismatch',f'Modeled recovery differs for {register} on a '+('known-reachable' if certain else 'conservative possible')+' CFG path',pc,want.describe(),got.describe()))
    if unknown_count:
        return unresolved('unknown_recovery_value',f'{unknown_count} required CFG recovery values are unknown',scope=scope)
    if mismatch_count and not known_witness:
        return unresolved('cfg_path_feasibility_unknown','A recovery discrepancy exists only on paths with uncertain reachability',scope=scope)
    if not observations or not terminals:
        return unresolved('no_supported_observation','No complete supported CFG path/observation exists')
    if not limits.max_evidence_per_function:
        return unresolved('evidence_limit','No concrete CFG recovery evidence can be retained',scope=scope)
    # Prioritize a known-reachable witness when evidence storage is bounded.
    if mismatch_count:
        known=[]
        for pc,recovered,certain in observations:
            if not certain:continue
            for register,want in expected.items():
                got=recovered[register]
                if got.known and got!=want and len(known)<limits.max_evidence_per_function:
                    known.append(Evidence('caller_state_mismatch',f'Modeled recovery differs for {register} on a known-reachable CFG path',pc,want.describe(),got.describe()))
        evidence=known
    else:evidence=[Evidence('caller_state_recovered','Modeled recovery preserves entry SP and original x19–x30 at every listed conservative CFG observation')]
    if loops:
        headers=', '.join(f'{instructions[index].address:#x}' for index in loops)
        evidence.append(Evidence('cfg_loop_checked',f'{len(loops)} decoded natural loop(s) at {headers}; {len(loop_members)} distinct instructions; {loop_visits} distinct path-header states; {loop_closures} exact recurrent paths closed; all explored exits retained; no termination or execution-count claim',instructions[next(iter(loops))].address))
    if len(returns)>1:
        evidence.append(Evidence('cfg_returns_checked',f'{len(returns)} decoded RET x30 terminals with {len(signatures)} distinct contiguous teardown sequences; every explored terminal restored caller identities'))
    if shared_edges:
        evidence.append(Evidence('cfg_shared_teardown',f'{len(shared_edges)} forward restore-prefix transfers into recognized later teardown suffixes; incoming states retained separately'))
    conditional_count=sum(instructions[index].kind=='bcond' for index in shared_edges)
    if conditional_count:
        evidence.append(Evidence('cfg_conditional_teardown',f'{conditional_count} EQ–LE restore-prefix transfers have recognized taken and fallthrough teardown successors; unknown conditions fork separate states'))
    evidence.extend(cfi_evidence)
    evidence.extend(call_evidence)
    evidence.append(Evidence('cfg_paths_checked',f'{terminals} terminal paths checked; {speculative_terminals} with uncertain reachability; {steps} state visits; {len(observations)} path-state observations; states retained separately at reconvergence'+(f'; {no_call_terminals} paths without call observations' if allow_calls else '')))
    retained=evidence[:limits.max_evidence_per_function]
    if len(retained)<len(evidence) or mismatch_count>len(retained):
        limitations+=(f'Evidence display truncated; every collected path-state recovery was still compared.',)
    return AuditResult('inconsistency' if mismatch_count else 'agreement',coverage,mode,scope,
                       ('caller_state_mismatch' if mismatch_count else 'supported_model_agreement',),
                       tuple(sorted({pc for pc,_,_ in observations})),tuple(retained),limitations,count,cfg_steps=steps)


def audit_current_function(image: MachOImage, function: FunctionRange, entry: UnwindEntry | None,
                           limits: Limits = Limits(), *, cfi_table=None) -> AuditResult:
    """Current dispatch retains prior paths and extends only eligible failures."""
    from .audit import audit_function
    if image.architecture=='arm64' and image.cpu_subtype not in (0,1):
        mode=encoding_mode(entry.encoding) if entry else 'none'
        coverage=('dwarf_reference' if mode=='dwarf' else 'compact') if entry and entry.encoding else 'none'
        return AuditResult('unresolved',coverage,mode,'metadata_only',('unsupported_current_cpu_subtype',),
                           evidence=(Evidence('unsupported_current_cpu_subtype','The current model requires exact ordinary ARM64 subtype0 or1'),)[:limits.max_evidence_per_function],limitations=MODEL_LIMITATIONS)
    result=audit_function(image,function,entry,limits,cfi_table=cfi_table)
    if entry is not None and result.reason_codes in (('unsupported_instruction',),('unsupported_control_flow',),('non_nop_after_return',)):
        if encoding_mode(entry.encoding)=='frameless':
            return audit_cfg_function(image,function,entry,limits)
        if encoding_mode(entry.encoding)=='dwarf':
            return audit_cfg_function(image,function,entry,limits,allow_calls=True,cfi_table=cfi_table)
        if encoding_mode(entry.encoding)=='frame':
            return audit_cfg_calls_function(image,function,entry,limits)
    return result


def audit_cfg_calls_function(image: MachOImage, function: FunctionRange, entry: UnwindEntry | None,
                             limits: Limits = Limits()) -> AuditResult:
    """v4 compact-frame CFG calls; callers use synchronous BL suspension states."""
    return audit_cfg_function(image,function,entry,limits,allow_calls=True)
