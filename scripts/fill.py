#!/usr/bin/env python3
"""Pack an INT8 matrix into the DUT's 32-bit activation/weight memory words."""

import argparse
from pathlib import Path
import re


def convert(input_path, output_path, rows, cols, offset=0):
    if any(size < 4 or size > 64 or size % 4 for size in (rows, cols)):
        raise ValueError('M and N must be multiples of 4 between 4 and 64')
    if offset < 0 or offset + rows * (cols // 4) > 1024:
        raise ValueError('Matrix and offset must fit the 1024-word memory')
    matrix = []
    for line in Path(input_path).read_text().splitlines():
        if not line.strip():
            continue
        tokens = line.split()
        if len(tokens) != cols or any(not re.fullmatch(r'(?:0[xX])?[0-9a-fA-F]{1,2}', token)
                                      for token in tokens):
            raise ValueError('Each matrix row must contain N hexadecimal INT8 elements')
        matrix.append([int(token, 16) for token in tokens])
    if len(matrix) != rows:
        raise ValueError('Expected {} matrix rows, found {}'.format(rows, len(matrix)))
    words = []
    if offset:
        words.append('@{:08X}'.format(offset))
    # Tile columns first, then rows; the first column occupies the least significant byte.
    for col in range(0, cols, 4):
        for row in matrix:
            word = sum(row[col + lane] << (8 * lane) for lane in range(4))
            words.append('{:08X}'.format(word))
    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('\n'.join(words) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input_mat', required=True)
    parser.add_argument('--output_mat', required=True)
    parser.add_argument('--M', type=int, required=True, help='Rows of the matrix being converted')
    parser.add_argument('--N', type=int, required=True, help='Columns of the matrix being converted')
    parser.add_argument('--offset', type=int, default=0, help='Optional starting word address (default: 0)')
    args = parser.parse_args()
    try:
        convert(args.input_mat, args.output_mat, args.M, args.N, args.offset)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
