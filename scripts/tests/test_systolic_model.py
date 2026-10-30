import random
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from systolic_model import (BistSimulator, ExternalSimulator, Simulator, make_memory,
                            final_result, next_pattern, next_signature, pack, read_matrix, stop_code, unpack, write_matrix)


def reference(a, b, relu=False):
    output = []
    for row in a:
        values = []
        for col in range(len(b[0])):
            saved = 0
            for first in range(0, len(b), 4):
                total = saved + sum(row[k] * b[k][col] for k in range(first, first + 4))
                if first + 4 < len(b):
                    saved = min(32767, max(-32768, total))
                else:
                    saved = min(127, max(-128, total))
                    if relu:
                        saved = max(0, saved)
            values.append(saved)
        output.append(values)
    return output


class ModelTests(unittest.TestCase):
    def test_zero_middle_tiles_preserve_results_and_shorten_schedule(self):
        rng = random.Random(3100)
        for m, n, k in [(4, 8, 16), (8, 8, 4), (8, 8, 8),
                        (8, 8, 12), (12, 12, 20), (64, 64, 64)]:
            a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(m)]
            b = [[rng.randrange(-128, 128) for _ in range(n)] for _ in range(k)]
            for nt in range(n // 4):
                for kt in range(k // 4):
                    if (kt + nt) % 2:
                        for r in range(4):
                            b[kt * 4 + r][nt * 4:nt * 4 + 4] = [0] * 4
            count = sum(all(b[kt * 4 + r][nt * 4 + c] == 0
                            for r in range(4) for c in range(4))
                        for nt in range(n // 4) for kt in range(1, k // 4 - 1)) if m > 5 else 0
            for relu in (False, True):
                with self.subTest(m=m, n=n, k=k, relu=relu):
                    dense = Simulator(a, b, relu=relu)
                    sparse = Simulator(a, b, relu=relu, zero_tile=True)
                    self.assertEqual(dense.run(), reference(a, b, relu))
                    self.assertEqual(sparse.run(), dense.read_output())
                    self.assertEqual(sparse.skipped_tiles, count)
                    self.assertEqual(dense.compute_cycles - sparse.compute_cycles, count * (m - 5))
                    self.assertEqual(dense.partial_sum_writes - sparse.partial_sum_writes, count * (m - 5))
                    self.assertEqual(dense.weight_tile_order, sparse.weight_tile_order)

    def test_zero_detection_checks_every_weight_row(self):
        for row in range(4):
            a = [[127] * 12 for _ in range(8)]
            b = [[0] * 4 for _ in range(12)]
            b[4 + row][row] = -128
            sim = Simulator(a, b, zero_tile=True)
            self.assertEqual(sim.run(), reference(a, b))
            self.assertEqual(sim.skipped_tiles, 0)
            self.assertEqual(sim.compute_cycles, 32)

    def test_memory_layout_and_offsets(self):
        a = [[row * 16 + col - 64 for col in range(8)] for row in range(8)]
        memory = make_memory(a, 7)
        self.assertEqual(pack([-2, 4, -7, 7]), 0x07F904FE)
        for col in range(2):
            for row in range(8):
                self.assertEqual(unpack(memory[7 + col * 8 + row]), a[row][col * 4:col * 4 + 4])
        self.assertEqual(memory[:7], [0] * 7)
        self.assertEqual(memory[23:], [0] * (1024 - 23))

    def test_tiled_memory_results_and_cycles(self):
        rng = random.Random(8804)
        shapes = [(4, 4, 4), (8, 8, 8), (12, 8, 16), (4, 12, 8),
                  (16, 4, 12), (64, 64, 64)]
        shapes += [(4 * rng.randrange(1, 5), 4 * rng.randrange(1, 5),
                    4 * rng.randrange(1, 5)) for _ in range(12)]
        for m, n, k in shapes:
            with self.subTest(m=m, n=n, k=k):
                a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(m)]
                b = [[rng.randrange(-128, 128) for _ in range(n)] for _ in range(k)]
                offset = 0 if m == 64 else 7
                sim = Simulator(a, b, offset, offset, offset)
                expected = reference(a, b)
                self.assertEqual(sim.run(), expected)
                self.assertEqual(sim.compute_cycles, m * (k // 4) * (n // 4) + 8)
                self.assertEqual(sim.partial_sum_writes, m * (k // 4) * (n // 4))
                self.assertEqual(sim.weight_loads, (k // 4) * (n // 4))
                self.assertEqual(sim.weight_tile_order,
                                 [(kt, nt) for nt in range(n // 4) for kt in range(k // 4)])
                for nt in range(n // 4):
                    for row in range(m):
                        self.assertEqual(unpack(sim.partial_sum_memory[offset + nt * m + row], 16),
                                         expected[row][nt * 4:nt * 4 + 4])
                with self.assertRaises(ValueError):
                    sim.run()

    def test_intermediate_saturation_and_final_relu(self):
        for sign, expected in [(1, -128), (-1, 127)]:
            a = [[sign * 127] * 4 + [-sign * 127] * 4 for _ in range(4)]
            b = [[127] * 4 for _ in range(8)]
            for relu in (False, True):
                sim = Simulator(a, b, relu=relu)
                final = max(0, expected) if relu else expected
                self.assertEqual(sim.run(), [[final] * 4 for _ in range(4)])
                self.assertEqual(sim.saturation_events, 16)
        a = [[127, 127, -127, -127] for _ in range(4)]
        sim = Simulator(a, [[127] * 4 for _ in range(4)])
        self.assertEqual(sim.run(), [[0] * 4 for _ in range(4)])
        self.assertEqual(sim.saturation_events, 0)
        self.assertEqual(Simulator([[-128] * 4 for _ in range(4)],
                                   [[-128] * 4 for _ in range(4)]).run(),
                         [[127] * 4 for _ in range(4)])

    def test_external_gaps_and_drain(self):
        rng = random.Random(18)
        b = [[rng.randrange(-7, 8) for _ in range(4)] for _ in range(4)]
        a = [[rng.randrange(-128, 128) for _ in range(4)] for _ in range(25)]
        sim = ExternalSimulator()
        sim.load_weights(b)
        for index, row in enumerate(a):
            sim.step(row)
            if index % 3 == 1:
                sim.step()
                sim.step()
        self.assertEqual(sim.drain(), reference(a, b))
        self.assertEqual(sim.inputs_seen, 25)
        self.assertEqual(sim.outputs_seen, 25)
        self.assertEqual(sim.pending_count, 0)
        for _ in range(10):
            self.assertIsNone(sim.step())

    def test_concurrent_weight_loading_and_mac(self):
        rng = random.Random(4)
        a = [[rng.randrange(-8, 9) for _ in range(4)] for _ in range(12)]
        matrices = [[[rng.randrange(-7, 8) for _ in range(4)] for _ in range(4)]
                    for _ in range(3)]
        sim = ExternalSimulator()
        for index, row in enumerate(a):
            sim.step(row, weights=matrices[index // 4][index % 4],
                     weight_en=index % 4 == 0)
        expected = []
        for tile in range(3):
            expected.extend(reference(a[tile * 4:tile * 4 + 4], matrices[tile]))
        self.assertEqual(sim.drain(), expected)
        self.assertEqual(sim.cycles, 12 + 7)

    def test_bist_signature_stop_and_pauses(self):
        rng = random.Random(64)
        weights = [[rng.randrange(-7, 8) for _ in range(4)] for _ in range(4)]
        for patterns, valid in [(0, (True,)), (1, (True,)), (4, (True,)),
                                (32, (True,)), (25, (True, False, True, True))]:
            with self.subTest(patterns=patterns, valid=valid):
                seed = 0x123456789abcdef0 ^ patterns
                state = seed
                a = []
                for _ in range(patterns):
                    state = next_pattern(state)
                    a.append(unpack(state >> 32))
                expected = reference(a, weights)
                signature = ((seed & 0xffffffff) << 32) | (seed >> 32)
                sim = BistSimulator(seed, state)
                self.assertEqual(sim.run(weights, valid), expected)
                self.assertEqual(sim.compressed_results, expected[:len(sim.compressed_results)])
                if patterns:
                    self.assertLess(len(sim.compressed_results), patterns)
                for row in sim.compressed_results:
                    signature = next_signature(signature) ^ pack(row)
                self.assertEqual(sim.signature, signature)
                self.assertTrue(sim.signature_valid)
                self.assertTrue(sim.driver.done)
                self.assertEqual(sim.inputs_seen, patterns)
                self.assertEqual(sim.outputs_seen, patterns)
                self.assertEqual(sim.pending_count, 0)
                for _ in range(4):
                    self.assertEqual(sim.step(), signature)

    def test_lfsr_tap_positions(self):
        self.assertEqual(next_pattern(0), 0)
        self.assertEqual(next_pattern(1 << 63), 1)
        for bit in (62, 61, 52):
            self.assertEqual(next_pattern(1 << bit), (1 << (bit + 1)) | 1)
        self.assertEqual(next_pattern(1 << 60), 1 << 61)
        self.assertEqual(next_signature(1 << 63), 0)
        for bit in (62, 61, 60, 51):
            self.assertEqual(next_signature(1 << bit), (1 << (bit + 1)) | 1)
        self.assertEqual(next_pattern((1 << 64) - 1), (1 << 64) - 2)
        self.assertEqual(stop_code(1, 4), 16)

    def test_optional_relu_all_paths(self):
        self.assertEqual(final_result(-1), -1)
        values = [-1000, -129, -128, -1, 0, 127, 128, 1000]
        self.assertEqual([final_result(v) for v in values],
                         [-128, -128, -128, -1, 0, 127, 127, 127])
        self.assertEqual([final_result(v, True) for v in values],
                         [0, 0, 0, 0, 0, 127, 127, 127])
        a = [[-128, -1, 0, 127, 7, -8, 1, -2] for _ in range(8)]
        identity8 = [[int(r == c) for c in range(8)] for r in range(8)]
        identity4 = [[int(r == c) for c in range(4)] for r in range(4)]
        seed = 0x123456789abcdef0
        for relu in (False, True):
            with self.subTest(relu=relu):
                memory = Simulator(a, identity8, relu=relu)
                self.assertEqual(memory.run(), reference(a, identity8, relu))
                external = ExternalSimulator(relu=relu)
                external.load_weights(identity4)
                for row in a:
                    external.step(row[:4])
                    external.step()
                self.assertEqual(external.drain(), reference([row[:4] for row in a], identity4, relu))
                state, inputs = seed, []
                for _ in range(16):
                    state = next_pattern(state)
                    inputs.append(unpack(state >> 32))
                expected = reference(inputs, identity4, relu)
                signature = ((seed & 0xffffffff) << 32) | (seed >> 32)
                bist = BistSimulator(seed, state, relu=relu)
                self.assertEqual(bist.run(identity4, (True, False, True)), expected)
                for row in bist.compressed_results:
                    signature = next_signature(signature) ^ pack(row)
                self.assertEqual(bist.signature, signature)

    def test_cli_modes(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            a_file, b_file, c_file = (folder / name for name in ('A.txt', 'B.txt', 'C.txt'))
            a = [[-128, 127, -1, 1], [5, -3, 2, 0], [0] * 4, [127] * 4]
            b = [[int(row == col) for col in range(4)] for row in range(4)]
            write_matrix(a_file, a)
            write_matrix(b_file, b)
            for mode in ('memory', 'external', 'bist'):
                args = {'memory': ['4', '4', '4', str(a_file), str(b_file), str(c_file)],
                        'external': ['4', str(a_file), str(b_file), str(c_file), '--valid-pattern', '101'],
                        'bist': [str(b_file), str(c_file), '--patterns', '4', '--valid-pattern', '1101']}[mode]
                for relu in (False, True):
                    command = [sys.executable, str(SCRIPTS / 'systolic_model.py'), mode] + args
                    if relu:
                        command.append('--relu')
                    result = subprocess.run(command, cwd=folder, universal_newlines=True,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    output = read_matrix(c_file, 4, 4)
                    if mode != 'bist':
                        self.assertEqual(output, reference(a, b, relu))
                    else:
                        self.assertIn('signature:', result.stdout)

    def test_invalid_inputs(self):
        a = [[1] * 4 for _ in range(4)]
        for kwargs in ({'act_offset': -1}, {'wgt_offset': 1022}, {'rst_offset': 1022}):
            with self.assertRaises(ValueError):
                Simulator(a, a, **kwargs)
        for invalid in ([], [[1]], [[128] * 4 for _ in range(4)]):
            with self.assertRaises(ValueError):
                Simulator(invalid, a)
        with self.assertRaises(ValueError):
            ExternalSimulator().step([0, 0, 0, 128])
        with self.assertRaises(ValueError):
            BistSimulator(-1, 0)
        with self.assertRaises(ValueError):
            stop_code(1, -1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
