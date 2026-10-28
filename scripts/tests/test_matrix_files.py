from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class MatrixFileTests(unittest.TestCase):
    def run_script(self, name, source, destination, rows, cols, offset=0):
        return subprocess.run([sys.executable, str(SCRIPTS / name),
                               '--input_mat', str(source), '--output_mat', str(destination),
                               '--M', str(rows), '--N', str(cols), '--offset', str(offset)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True)

    def test_fill_matches_provided_readmemh_example(self):
        root = SCRIPTS.parent
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'B.txt'
            source.write_text('FE 04 F9 07\nFB 05 02 03\n04 FB FA FB\n06 FD FD 06\n')
            destination = Path(folder) / 'new' / 'nested' / 'B.mem'
            result = self.run_script('fill.py', source, destination, 4, 4)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.read_text().split(),
                             (root / 'src/verilog/tests/example/WEIGHT_MEM_2.hex').read_text().split())

    def test_fill_tile_column_order_non_square_and_max_size(self):
        for rows, cols, offset in [(12, 8, 7), (8, 12, 3), (64, 64, 0)]:
            with self.subTest(rows=rows, cols=cols), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                matrix = [[(r * 41 + c * 17) & 255 for c in range(cols)] for r in range(rows)]
                source = folder / 'A.txt'
                source.write_text(''.join(' '.join('{:02X}'.format(v) for v in row) + '\n' for row in matrix))
                destination = folder / 'A.mem'
                result = self.run_script('fill.py', source, destination, rows, cols, offset)
                self.assertEqual(result.returncode, 0, result.stderr)
                words = destination.read_text().split()
                if offset:
                    self.assertEqual(words.pop(0), '@{:08X}'.format(offset))
                self.assertEqual(len(words), rows * cols // 4)
                for col in range(cols):
                    for row in range(rows):
                        word = int(words[(col // 4) * rows + row], 16)
                        self.assertEqual((word >> (8 * (col % 4))) & 255, matrix[row][col])

    def test_extract_writememh_comments_addresses_unknown_tail_and_signed_values(self):
        for rows, cols, offset in [(12, 8, 7), (8, 12, 3), (64, 64, 0)]:
            with self.subTest(rows=rows, cols=cols), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                matrix = [[((r * 41 + c * 17) & 255) - 128 for c in range(cols)] for r in range(rows)]
                lines = ['/* output memory */', '@{:08X}'.format(offset)]
                for col in range(0, cols, 4):
                    for row in matrix:
                        word = sum((row[col + lane] & 65535) << (16 * lane) for lane in range(4))
                        lines.append('{:016x} // word'.format(word))
                if offset + rows * cols // 4 < 1024:
                    lines.append('xxxxxxxxxxxxxxxx')
                source = folder / 'C.mem'
                source.write_text('\n'.join(lines))
                destination = folder / 'new' / 'C.txt'
                result = self.run_script('extract.py', source, destination, rows, cols, offset)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = ''.join(' '.join('{:02X}'.format(v & 255) for v in row) + '\n' for row in matrix)
                self.assertEqual(destination.read_text(), expected)

    def test_extract_rejects_missing_unknown_and_unclipped_output(self):
        for contents in ('', 'xxxxxxxxxxxxxxxx\n' * 4, '0000000000000080\n' * 4):
            with tempfile.TemporaryDirectory() as folder:
                source = Path(folder) / 'C.mem'
                source.write_text(contents)
                destination = Path(folder) / 'C.txt'
                result = self.run_script('extract.py', source, destination, 4, 4)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())

    def test_fill_rejects_bad_shapes_values_and_capacity(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'A.txt'
            destination = Path(folder) / 'A.mem'
            for contents, rows, cols, offset in [('00 01\n', 4, 4, 0),
                                                ('100 00 00 00\n' * 4, 4, 4, 0),
                                                ('00 00 00 00\n' * 4, 3, 4, 0),
                                                ('00 00 00 00\n' * 4, 4, 4, 1021)]:
                source.write_text(contents)
                result = self.run_script('fill.py', source, destination, rows, cols, offset)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
