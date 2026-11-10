"""Unsigned declarations must support float attachments without losing their integer bits or mixed-target entry points."""
import pathlib
import re
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'gfx/tools'))
import dmsh_entry
import dmsh_fetch
import dmsh_side

SOURCE = '''#include <metal_stdlib>
using namespace metal;
struct main0_out
{
    uint4 m_0 [[color(0)]];
    float4 m_1 [[color(1)]];
};
static void update(thread main0_out& out)
{
    out.m_0 ^= uint4(0x80000000u);
}
fragment main0_out main0(constant uint4& bits [[buffer(0)]])
{
    main0_out out = {};
    out.m_0 = bits ^ uint4(0x80000000u);
    update(out);
    out.m_1 = float4(0.25, 0.5, 0.75, 1.0);
    return out;
}
'''


class OutputTypes(unittest.TestCase):
    def test_original_unsigned_computations_and_references_stay_unsigned(self):
        src, names = dmsh_entry.fs_float(SOURCE)
        self.assertEqual(names, {'m_0'})
        self.assertIn('thread dm_uint_main0_out& out', src)
        self.assertIn('dm_uint_main0_out out = {};', src)
        self.assertIn('out.m_0 ^= uint4(0x80000000u);', src)
        self.assertIn('as_type<float4>(out.m_0)', src)
        self.assertNotIn('float4(out.m_0)', src)

    def test_declared_integer_writer_gets_unsigned_and_mixed_entries(self):
        src, names = dmsh_entry.fs_float(SOURCE)
        extra, mask = dmsh_entry.fs_uint(src, names)
        self.assertIsNotNone(extra)
        self.assertEqual(mask, 1)
        self.assertIn('main0_u(', extra)
        self.assertIn('main0_m(', extra)
        self.assertIn('as_type<uint4>(out.m_0)', extra)

    def test_every_early_return_reinterprets_the_output(self):
        original = SOURCE.replace('    update(out);', '    if (bits.x == 0u) return out;\n    update(out);')
        src, _ = dmsh_entry.fs_float(original)
        self.assertEqual(src.count('return main0_out{'), 2)
        self.assertNotIn('return out;', src)

    def test_declared_mixed_signature_wins_over_inferred_integer_writes(self):
        src, names = dmsh_entry.fs_float(SOURCE.replace('out.m_1 = float4(0.25, 0.5, 0.75, 1.0);', 'out.m_1.x = as_type<float>(1u);'))
        extra, mask = dmsh_entry.fs_uint(src, names)
        self.assertIsNotNone(extra)
        self.assertEqual(mask, 1)

    def test_unknown_members_fail_instead_of_dropping_an_output(self):
        src = SOURCE.replace('    float4 m_1 [[color(1)]];', '    float4 m_1 [[color(1)]];\n    uint values[2];')
        with self.assertRaisesRegex(ValueError, 'unknown member'): dmsh_entry.fs_float(src)

    def test_normalizing_twice_changes_nothing_more(self):
        src, _ = dmsh_entry.fs_float(SOURCE)
        self.assertEqual(dmsh_entry.fs_float(src), (src, set()))

    def test_floating_and_signed_declarations_are_unchanged(self):
        for ty in ('float4', 'int4'):
            src = SOURCE.replace('uint4 m_0', ty + ' m_0')
            self.assertEqual(dmsh_entry.fs_float(src), (src, set()))

    def test_readable_tile_and_side_entries_keep_the_original_body(self):
        src, names = dmsh_entry.fs_float(SOURCE)
        extra, _ = dmsh_entry.fs_uint(src, names)
        full = dmsh_side.shared_body(src) + extra
        unit, info = dmsh_side.unit(full)
        self.assertTrue(unit)
        self.assertIn('main0_u_l', info['logic'])
        folded, meta = dmsh_fetch.fold(unit, [], om_only_ok=True)
        self.assertTrue(folded)
        self.assertEqual(meta['outputs'], [{'color': 0, 'type': 'float4'}, {'color': 1, 'type': 'float4'}])
        self.assertEqual(folded.count('out.m_0 = bits ^ uint4(0x80000000u);'), 1)


def fixture(folder):
    """Synthetic shaders for t_output_types: the actual generator's entries, plus an unsigned reference and a full-screen triangle."""
    folder = pathlib.Path(folder); folder.mkdir(parents=True, exist_ok=True)
    src = SOURCE.replace('constant uint4& bits [[buffer(0)]]', 'float4 position [[position]], device const uint* words [[buffer(0)]]')
    src = src.replace('main0_out out = {};', 'main0_out out = {};\n    uint4 bits = uint4(words[uint(position.x)]);')
    ref = re.sub(r'\b(main0_out|main0|update)\b', lambda m: {'main0_out': 'reference_out', 'main0': 'originalOut', 'update': 'reference_update'}[m[0]], src)
    src, names = dmsh_entry.fs_float(src)
    extra, mask = dmsh_entry.fs_uint(src, names)
    if not extra or mask != 1: raise ValueError('the fixture needs unsigned and mixed entries')
    src = dmsh_side.shared_body(src) + extra + '\n' + ref
    src += '\nvertex float4 vs(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i],0,1); }\n'
    metal, air, lib = (folder / ('output_types.' + s) for s in ('metal', 'air', 'metallib'))
    metal.write_text(src)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-O1', '-fpreserve-invariance', '-fmodules-cache-path=' + str(folder / 'modules'), str(metal), '-o', str(air)], check=True)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(air), '-o', str(lib)], check=True)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture': fixture(sys.argv[2])
    else: unittest.main()
