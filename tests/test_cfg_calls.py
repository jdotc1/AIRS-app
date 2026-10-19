"""Small owned call graphs as bytes; no inspected code is executed."""
from dataclasses import replace
import struct
import unittest

from airs import cfg
from airs.arm64 import ModelError, Value, original
from airs.types import FunctionRange, Limits, Section
from test_audit import fixture, BASE, NOP, RET

CALL='BL-owned-entry'
# Same canonical frame words as the retained independent Apple disassembly.
PRO=(0xa9bf7bfd,0x910003fd)
EPI=(0xa8c17bfd,RET)
CHOICE=(*PRO,0x71001c1f,0x5400006d,CALL,0x14000002,CALL,*EPI)
SKIP=(*PRO,0x71001c1f,0x5400004c,CALL,*EPI)
FLAGS=(*PRO,0xd2800100,0x71001c1f,CALL,0x5400006c,NOP,0x14000002,CALL,*EPI)
PAIR_PRO=(0xd10083ff,0xa9004ff4,0xa9017bfd,0x910043fd)
PAIR_EPI=(0xa9417bfd,0xa9404ff4,0x910083ff,RET)
PAIR_BAD=(*PAIR_PRO,0xd2800100,0x71001c1f,0x5400006d,0xd28000f3,CALL,*PAIR_EPI)


def call_fixture(words=CHOICE,encoding=0x04000000,**kwargs):
    # Independent literal BL field assembly; expected PCs below are hand-selected.
    words=tuple((0x94000000 | ((0x100-index*4)//4)) if word==CALL else word for index,word in enumerate(words))
    image,fn,entry=fixture(words,encoding,**kwargs)
    padding=bytes(0x100-len(image.data))
    callee=FunctionRange(BASE+0x100,BASE+0x108,'owned_sink','lc_function_starts')
    data=image.data+padding+struct.pack('<II',NOP,RET)
    image=replace(image,data=data,slice_size=len(data),sections=(replace(image.sections[0],size=len(data)),),functions=(fn,callee))
    return image,fn,entry


def check(words=CHOICE,encoding=0x04000000,limits=Limits(),**kwargs):
    return cfg.audit_cfg_calls_function(*call_fixture(words,encoding,**kwargs),limits=limits)


class CFGCallRecoveryTests(unittest.TestCase):
    def test_conditional_calls_observe_only_bl_pcs_after_lr_write(self):
        result=check()
        self.assertEqual((result.verdict,result.coverage,result.mode,result.scope),('agreement','compact','frame','synchronous_call_sites'))
        self.assertEqual(result.checked_pcs,(BASE+16,BASE+24))
        links=[e for e in result.evidence if e.code=='cfg_call_site']
        self.assertEqual([(e.address,e.expected,e.observed) for e in links],
                         [(BASE+16,'constant 0x1014','constant 0x1014'),(BASE+24,'constant 0x101c','constant 0x101c')])

    def test_callee_flags_and_volatiles_are_unknown_after_resume(self):
        result=check(FLAGS)
        self.assertEqual(result.verdict,'agreement')
        self.assertEqual(result.checked_pcs,(BASE+16,BASE+32))
        self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
        state=cfg.PathState()
        state.registers[0]=Value('constant',8)
        state.apply(cfg.decode_instruction(0x71001c1f,BASE))
        self.assertTrue(state.condition(12))
        state.apply(cfg.decode_instruction(0x94000040,BASE))
        self.assertEqual(state.registers[30],Value('constant',BASE+4))
        state.resume_after_call()
        self.assertIsNone(state.condition(12));self.assertFalse(state.registers[0].known)
        self.assertFalse(state.registers[30].known);self.assertEqual(state.registers[19],original(19))

    def test_no_call_paths_restore_return_without_inventing_observations(self):
        result=check(SKIP)
        self.assertEqual((result.verdict,result.checked_pcs),('agreement',(BASE+16,)))
        self.assertTrue(any('1 paths without call observations' in e.message for e in result.evidence))
        result=check((*PRO,0xd2800100,0x71001c1f,0x5400004c,CALL,*EPI))
        self.assertEqual((result.verdict,result.reason_codes,result.checked_pcs),('unresolved',('no_supported_observation',),()))

    def test_saved_integer_pairs_agree_or_keep_known_recovery_discrepancy(self):
        self.assertEqual(check(PAIR_BAD,0x04000001).verdict,'agreement')
        result=check(PAIR_BAD,0x04000000)
        self.assertEqual(result.verdict,'inconsistency')
        self.assertEqual(result.checked_pcs,(BASE+32,))
        self.assertTrue(any(e.expected=='original x19' and e.observed=='constant 0x7' for e in result.evidence))

    def test_possible_only_defect_and_unknown_recovery_never_become_supported(self):
        uncertain=(*PAIR_PRO,0x71001c1f,0x5400006d,0xd28000f3,CALL,*PAIR_EPI)
        result=check(uncertain,0x04000000)
        self.assertEqual((result.verdict,result.reason_codes),('unresolved',('cfg_path_feasibility_unknown',)))
        unknown=(*PAIR_PRO,0x11000013,0x71001c1f,0x5400004d,CALL,*PAIR_EPI)
        self.assertEqual(check(unknown,0x04000000,limits=replace(Limits(),max_evidence_per_function=1)).verdict,'unresolved')

    def test_call_after_call_cannot_reuse_old_volatile_identity(self):
        # X9 copied from preserved X19 is volatile at the call; restoration from
        # X9 after resume is unknown even though X19 itself remains preserved.
        words=(*PAIR_PRO,0xaa1303e9,CALL,0xaa0903f3,CALL,*PAIR_EPI)
        result=check(words,0x04000000)
        self.assertEqual((result.verdict,result.reason_codes),('unresolved',('unknown_recovery_value',)))

    def test_call_targets_require_distinct_independent_entries_even_when_dead(self):
        image,fn,entry=call_fixture()
        for changed in (replace(image,functions=(fn,)),replace(image,functions=(fn,replace(image.functions[1],boundary_source='symbol_table')))):
            with self.subTest(functions=changed.functions):self.assertEqual(cfg.audit_cfg_calls_function(changed,fn,entry).verdict,'unresolved')
        for word in (0x94000000,0x97fffffc,0x9400003b):
            words=list(CHOICE);words[4]=word
            self.assertEqual(check(tuple(words)).verdict,'unresolved')

    def test_no_call_on_unsupported_teardown_or_frame_edge_is_accepted(self):
        for index,word in ((3,0x14000005),(3,0x17ffffff),(2,0x910043ff)):
            words=list(CHOICE);words[index]=word
            self.assertEqual(check(tuple(words)).verdict,'unresolved')
        # A branch may enter only the start of shared LDP/LDP/ADD teardown.
        words=list(PAIR_BAD);words[6]=0x14000005 # middle teardown
        self.assertEqual(check(tuple(words),0x04000001).verdict,'unresolved')

    def test_direct_and_truncated_stack_address_escapes_remain_unresolved(self):
        bodies=((0x910003e0,), # ADD X0,SP,#0
                (0x910003e9,0x11000120), # X9=SP then W0=W9+0
                (0xa93f7fa9,0xb94003e0), # store stack-derived X9 then Wload
                (0x910003e9,0xa93f7fa9,0xb90003e0))
        for body in bodies:
            with self.subTest(body=body):self.assertEqual(check((*PRO,*body,0x71001c1f,0x5400004c,CALL,*EPI)).verdict,'unresolved')

    def test_unknown_no_call_return_and_partial_saved_lr_overwrite_override_defect(self):
        # No-call branch corrupts LR; call branch alone cannot justify agreement.
        words=(*PRO,0x71001c1f,0x5400006c,CALL,0x14000002,0xd280001e,0xaa1e03e9,*EPI)
        # Shared epilogue restores LR, so overwrite its saved slot instead.
        words=(*PRO,0x71001c1f,0x5400006c,CALL,0x14000002,0xb9000fe0,*EPI)
        self.assertEqual(check(words).verdict,'unresolved')

    def test_limits_and_unsupported_metadata_preserve_unresolved(self):
        for changes in ({'max_observations_per_function':1},{'max_cfg_paths_per_function':1},{'max_cfg_steps_per_function':1},{'max_evidence_per_function':0}):
            self.assertEqual(check(limits=replace(Limits(),**changes)).verdict,'unresolved')
        for encoding in (0x02000000,0x03000000,0x05000000,0x04000100,0x04000020):
            self.assertEqual(check(encoding=encoding).verdict,'unresolved')
        for kwargs in ({'arch':'arm64e'},{'boundary':'symbol_table'}):
            self.assertEqual(check(**kwargs).verdict,'unresolved')

class CFGCallBoundaryTests(unittest.TestCase):
    def test_stack_address_projection_and_partial_store_are_explicit_declines(self):
        cases=(((*PRO,0x910003e0,CALL,*EPI),'stack_address_escapes_call'),
               ((*PRO,0x910003e9,0x11000120,CALL,*EPI),'stack_address_truncation_not_modeled'),
               ((*PAIR_PRO,0x910003e9,0xa9007fe9,0xb94003e0,CALL,*PAIR_EPI),'stack_address_truncation_not_modeled'),
               ((*PAIR_PRO,0x910003e9,0xa9007fe9,0xb90007e0,CALL,*PAIR_EPI),'partial_stack_address_not_modeled'))
        for words,reason in cases:
            with self.subTest(reason=reason,words=words):
                self.assertEqual(check(words).reason_codes,(reason,))

    def test_strict_projection_guard_is_preserved_on_copied_path(self):
        words=(*PRO,0x71001c1f,0x5400006c,CALL,0x14000004,0x910003e9,0x11000120,CALL,*EPI)
        self.assertEqual(check(words).reason_codes,('stack_address_truncation_not_modeled',))

    def test_word_cache_survives_unescaped_call_but_flags_must_be_recomputed(self):
        pro=(0xd10083ff,0xa9017bfd,0x910043fd)
        epi=(0xa9417bfd,0x910083ff,RET)
        words=(*pro,0xd2800100,0xb90003e0,CALL,0xb94003e8,0x71001d1f,0x5400004c,NOP,CALL,*epi)
        result=check(words)
        self.assertEqual((result.verdict,result.checked_pcs),('agreement',(BASE+20,BASE+40)))
        self.assertTrue(any('1 terminal paths' in e.message for e in result.evidence))

    def test_reconverged_call_checks_both_states_and_bad_no_call_return_declines(self):
        words=(*PAIR_PRO,0x71001c1f,0x5400004d,0xd28000f3,CALL,*PAIR_EPI)
        self.assertEqual(check(words).reason_codes,('cfg_path_feasibility_unknown',))
        words=(*PRO,0x71001c1f,0x5400006c,CALL,0x14000002,0xb9000fe0,*EPI)
        self.assertEqual(check(words).reason_codes,('unknown_stack_read',))
