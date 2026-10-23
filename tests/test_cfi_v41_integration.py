"""Literal CFI control streams; expected rows do not use production encoders."""
from dataclasses import replace
import unittest

from airs import dwarf_cfi
from airs.audit import audit_function as _audit_function
from airs.types import InputError, Limits
from test_audit import BASE
from test_dwarf_cfi import CIE, FRAME_CFI, eh_image
from test_fde_local_refusal import pair


def fde_for(parts):
    image, function, entry = parts
    return dwarf_cfi.parse_eh_frame(image, enable_cfi_controls=True).select(
        entry.encoding & 0xffffff, function)


def audit_function(image, function, entry, *, limits=Limits()):
    try:
        table = dwarf_cfi.parse_eh_frame(image, limits, enable_cfi_controls=True)
    except InputError:
        # Supply an explicitly refused table; the historical direct fallback is
        # deliberately outside the v41 API under test.
        fde = dwarf_cfi.FDE(entry.encoding & 0xffffff, 0, function.start,
                             function.end, (), 'v41 CFI parse refused')
        table = dwarf_cfi.CFITable({fde.offset: fde}, frozenset())
    return _audit_function(image, function, entry, limits=limits, cfi_table=table)


# The same framed function as FRAME_CFI, expressed with all three fixed-width
# advances and a temporary rule restored before its observation at BL +12.
CONTROL_FRAME_CFI = bytes.fromhex(
    '02040e109d029e01'       # +4: CFA=SP+16, FP/LR in their saved slots
    '0304000c1d10'         # +8: CFA=FP+16
    '0a07130b'             # remember; x19 undefined; restore x19 same_value
    '040c0000000c1f00ddde' # +20: epilogue has restored SP/FP/LR
)


def rows_for(code, *, start=0, end=0x100, limits=Limits(), initial=None):
    if initial is None:
        initial = dwarf_cfi.Row(start, (31, 0), {n: ('same', 0) for n in range(19, 31)})
    return dwarf_cfi.program(dwarf_cfi.Reader(code, 0, len(code)), start, end,
                             initial, dwarf_cfi.Budget(limits), enable_cfi_controls=True)


class CFIControlTests(unittest.TestCase):
    def test_historical_default_and_v41_opt_in_are_separate(self):
        image, fn, entry = eh_image(program=CONTROL_FRAME_CFI)
        with self.assertRaises(InputError):
            dwarf_cfi.parse_eh_frame(image)
        self.assertEqual(fde_for((image, fn, entry)).row_at(BASE+12).cfa, (29,16))
        image, fn, entry = eh_image(program=FRAME_CFI+b'\x0a\x0b')
        old = dwarf_cfi.parse_eh_frame(image)
        with self.assertRaises(InputError):
            old.select(entry.encoding & 0xffffff, fn)
        self.assertIsNone(fde_for((image, fn, entry)).refusal)

    def test_control_failure_keeps_unrelated_fde_and_no_supported_prefix(self):
        for tail in (b'\x0b', b'\x0a\x0a', b'\x02', b'\x03\x01\x00'):
            with self.subTest(tail=tail):
                image, fn, entry, offset, other = pair(tail)
                table = dwarf_cfi.parse_eh_frame(image, replace(Limits(), max_cfi_state_depth=1),
                                                 enable_cfi_controls=True)
                self.assertIsNone(table.select(entry.encoding & 0xffffff, fn).refusal)
                self.assertEqual(table.fdes[offset].rows, ())
                with self.assertRaises(InputError):
                    table.select(offset, other)

    def test_refused_control_tail_still_reserves_global_budgets(self):
        image, *_ = pair(b'\x0b'+b'\xff'*8)
        for changes in ({'max_cfi_instructions':10}, {'max_cfi_rows':10}):
            with self.subTest(changes=changes), self.assertRaises(InputError):
                dwarf_cfi.parse_eh_frame(image, replace(Limits(), **changes), enable_cfi_controls=True)

    def test_extended_forms_and_state_pair_recover_frame_at_call(self):
        try:
            fde = fde_for(eh_image(program=CONTROL_FRAME_CFI))
        except InputError as error:
            self.fail(f'The bounded control family must decode: {error}')
        self.assertEqual([row.pc for row in fde.rows], [BASE, BASE+4, BASE+8, BASE+20])
        self.assertEqual(fde.row_at(BASE+12).cfa, (29, 16))
        self.assertEqual(fde.row_at(BASE+12).rules[19], ('same', 0))
        self.assertEqual(fde.row_at(BASE+12).rules[30], ('offset', -8))
        result = audit_function(*eh_image(program=CONTROL_FRAME_CFI))
        self.assertEqual((result.verdict, result.coverage, result.scope, result.checked_pcs),
                         ('agreement', 'dwarf_evaluated', 'synchronous_call_sites', (BASE+12,)))

    def test_fixed_width_advances_are_unsigned_little_endian_not_uleb(self):
        cases = ((b'\x02\x80', 128), (b'\x03\x00\x01', 256),
                 (b'\x04\x00\x00\x01\x00', 65536),
                 (b'\x04\xfc\xff\xff\xff', 4294967292))
        for code, delta in cases:
            with self.subTest(code=code):
                rows = rows_for(code+b'\x0e\x08', end=delta+4)
                self.assertEqual([(row.pc, row.cfa) for row in rows], [(0, (31, 0)), (delta, (31, 8))])

    def test_nested_snapshots_restore_cfa_and_rules_at_current_pc(self):
        # Save SP+0, then SP+16/x19 slot; restore at +8 and +12 respectively.
        code = bytes.fromhex('0a0e109301440a0e200713440b440b')
        try:
            rows = rows_for(code)
        except InputError as error:
            self.fail(f'Nested snapshots must decode: {error}')
        self.assertEqual([(row.pc, row.cfa, row.rules[19]) for row in rows], [
            (0, (31, 16), ('offset', -8)), (4, (31, 32), ('undefined', 0)),
            (8, (31, 16), ('offset', -8)), (12, (31, 0), ('same', 0)),
        ])
        self.assertEqual(rows[0].rules[19], ('offset', -8))
        self.assertEqual(rows[1].rules[19], ('undefined', 0))

    def test_restore_register_still_uses_post_cie_initial_rule(self):
        initial = dwarf_cfi.Row(0, (31, 0), {n: ('same', 0) for n in range(19, 31)})
        initial.rules[19] = ('offset', -16)
        # Remember x19 undefined; primary restore uses the CIE, then restore_state
        # reinstates the remembered undefined rule without changing its current PC.
        rows = rows_for(bytes.fromhex('07130ad3440b'), initial=initial)
        self.assertEqual(rows[0].rules[19], ('offset', -16))
        self.assertEqual((rows[1].pc, rows[1].rules[19]), (4, ('undefined', 0)))
        self.assertEqual(initial.rules[19], ('offset', -16))

    def test_snapshot_restores_cfa_register_and_does_not_alias_initial_rules(self):
        initial = dwarf_cfi.Row(0, (31, 16), {n: ('same', 0) for n in range(19, 31)})
        rows = rows_for(bytes.fromhex('0a0d1d0713440b440813'), initial=initial)
        self.assertEqual([(r.pc, r.cfa) for r in rows], [(0, (29, 16)), (4, (31, 16)), (8, (31, 16))])
        self.assertEqual(rows[0].rules[19], ('undefined', 0))
        self.assertEqual(rows[1].rules[19], ('same', 0))
        self.assertEqual(initial.rules[19], ('same', 0))

    def test_pending_fde_snapshot_at_end_is_valid(self):
        fde = fde_for(eh_image(program=FRAME_CFI+b'\x0a'))
        self.assertEqual(fde.row_at(BASE+12).rules[30], ('offset', -8))
        self.assertEqual(audit_function(*eh_image(program=FRAME_CFI+b'\x0a')).verdict, 'agreement')

    def test_each_fixed_operand_truncation_declines(self):
        for opcode, width in ((2, 1), (3, 2), (4, 4)):
            for present in range(width):
                with self.subTest(opcode=opcode, present=present), self.assertRaisesRegex((InputError, dwarf_cfi.LocalProgramRefusal), 'Truncated'):
                    rows_for(bytes((opcode,))+bytes(present))

    def test_all_advance_forms_keep_positive_grid_and_range_gates(self):
        for opcode, width in ((2, 1), (3, 2), (4, 4)):
            for delta in (0, 1, 3, 8):
                with self.subTest(opcode=opcode, delta=delta), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                    rows_for(bytes((opcode,))+delta.to_bytes(width, 'little'), end=4)
        for opcode in (0x40, 0x41, 0x43, 0x48):
            with self.subTest(opcode=opcode), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                rows_for(bytes((opcode,)), end=4)

    def test_advance_to_exact_end_does_not_make_end_an_observation(self):
        fde = fde_for(eh_image(program=FRAME_CFI+b'\x02\x04'))
        self.assertEqual(fde.rows[-1].pc, BASE+24)
        self.assertEqual(fde.row_at(BASE+20).cfa, (31, 0))
        with self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
            fde.row_at(BASE+24)

    def test_advance_cannot_wrap_unsigned_address_space(self):
        for advance in (b'\x44', b'\x02\x04', b'\x03\x04\x00', b'\x04\x04\x00\x00\x00'):
            with self.subTest(advance=advance), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                rows_for(advance, start=(1 << 64)-4, end=1 << 64)
        rows = rows_for(b'\x04\x04\x00\x00\x00', start=(1 << 64)-8, end=(1 << 64)-4)
        self.assertEqual(rows[-1].pc, (1 << 64)-4)

    def test_cie_location_and_state_controls_remain_outside_subset(self):
        for code in (b'\x02\x04', b'\x03\x04\x00', b'\x04\x04\x00\x00\x00', b'\x0a', b'\x0b', b'\x0a\x0b'):
            with self.subTest(code=code), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                fde_for(eh_image(cie=CIE+code))

    def test_restore_underflow_and_late_faults_decline_complete_fde(self):
        # Parsing must continue after the BL and after a final boundary row.
        for tail in (b'\x0b', b'\x0a\x0b\x0b', b'\x0a\x0b\x0f',
                     b'\x0a\x0b\x04\x01', b'\x02\x04\x0b'):
            with self.subTest(tail=tail), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                fde_for(eh_image(program=FRAME_CFI+tail))
            result = audit_function(*eh_image(program=FRAME_CFI+tail))
            self.assertEqual((result.verdict, result.coverage, result.checked_pcs),
                             ('unresolved', 'dwarf_reference', ()))

    def test_state_restore_cannot_hide_unsupported_register_or_offset(self):
        cases = (b'\x07\x12', b'\x08\x1f', b'\x0d\x1c', b'\x0c\x20\x00',
                 b'\x0e'+b'\x80'*9+b'\x01', b'\x93'+b'\x80'*9+b'\x01')
        for bad in cases:
            with self.subTest(bad=bad), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                rows_for(b'\x0a'+bad+b'\x0b')

    def test_state_depth_budget_is_bounded_and_zero_only_disables_push(self):
        self.assertEqual(Limits().max_cfi_state_depth, 64)
        one = replace(Limits(), max_cfi_state_depth=1)
        self.assertEqual(rows_for(b'\x0a\x0b', limits=one)[-1].cfa, (31, 0))
        with self.assertRaisesRegex((InputError, dwarf_cfi.LocalProgramRefusal), 'state depth'):
            rows_for(b'\x0a\x0a', limits=one)
        zero = replace(one, max_cfi_state_depth=0)
        self.assertEqual(rows_for(b'\x00', limits=zero)[-1].cfa, (31, 0))
        with self.assertRaisesRegex((InputError, dwarf_cfi.LocalProgramRefusal), 'state depth'):
            rows_for(b'\x0a', limits=zero)
        for invalid in (-1, True, 1.0):
            with self.subTest(invalid=invalid), self.assertRaises((InputError, dwarf_cfi.LocalProgramRefusal)):
                replace(Limits(), max_cfi_state_depth=invalid)

    def test_new_operations_and_rows_share_existing_cfi_budgets(self):
        # Three opcodes, not three-plus-operand bytes; restore spends work too.
        code = bytes.fromhex('0a02040b')
        self.assertEqual(rows_for(code, limits=replace(Limits(), max_cfi_instructions=3))[-1].pc, 4)
        with self.assertRaisesRegex((InputError, dwarf_cfi.LocalProgramRefusal), 'instruction budget'):
            rows_for(code, limits=replace(Limits(), max_cfi_instructions=2))
        with self.assertRaisesRegex((InputError, dwarf_cfi.LocalProgramRefusal), 'row budget'):
            rows_for(code, limits=replace(Limits(), max_cfi_rows=1))

    def test_budget_exhaustion_after_observed_call_declines_complete_fde(self):
        cases = ((FRAME_CFI+b'\x0a\x0a', replace(Limits(), max_cfi_state_depth=1)),
                 # The CIE has one opcode, FRAME_CFI twelve, then two controls.
                 (FRAME_CFI+b'\x0a\x0b', replace(Limits(), max_cfi_instructions=14)))
        for code, limits in cases:
            with self.subTest(limits=limits):
                result = audit_function(*eh_image(program=code), limits=limits)
                self.assertEqual((result.verdict, result.coverage, result.checked_pcs),
                                 ('unresolved', 'dwarf_reference', ()))
                self.assertEqual(result.reason_codes, ('dwarf_cfi_unsupported',))

    def test_restored_unknown_dominates_concrete_mismatch(self):
        # LR points to saved FP, a concrete discrepancy; x19 was explicitly
        # undefined when remembered and must become unknown again on restoration.
        bad = CONTROL_FRAME_CFI.replace(b'\x9e\x01', b'\x9e\x02')
        bad = bad.replace(b'\x0a\x07\x13\x0b', b'\x07\x13\x0a\x08\x13\x0b')
        result = audit_function(*eh_image(program=bad))
        self.assertEqual((result.verdict, result.coverage, result.reason_codes),
                         ('unresolved', 'dwarf_evaluated', ('unknown_recovery_value',)))


if __name__ == '__main__':
    unittest.main()
