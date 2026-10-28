#!/usr/bin/env python3
"""Unpack a 64-bit output SRAM dump into the final signed INT8 matrix view."""

import argparse
from pathlib import Path
import re


def convert(input_path, output_path, rows, cols, offset=0):
    if any(size < 4 or size > 64 or size % 4 for size in (rows, cols)):
        raise ValueError('M and N must be multiples of 4 between 4 and 64')
    if offset < 0 or offset + rows * (cols // 4) > 1024:
        raise ValueError('Matrix and offset must fit the 1024-word memory')
    memory = {}
    address = 0
    text = re.sub(r'/\*.*?\*/', '', Path(input_path).read_text(), flags=re.S)
    for line in text.splitlines():
        for token in line.split('//', 1)[0].split():
            token = token.replace('_', '')
            if token.startswith('@'):
                if not re.fullmatch(r'@[0-9a-fA-F]+', token):
                    raise ValueError('Invalid memory address: ' + token)
                address = int(token[1:], 16)
                continue
            if not 0 <= address < 1024:
                raise ValueError('Memory address is outside the 1024-word SRAM')
            if not re.fullmatch(r'[0-9a-fA-FxXzZ]{1,16}', token):
                raise ValueError('Invalid 64-bit memory word: ' + token)
            memory[address] = None if re.search(r'[xXzZ]', token) else int(token, 16)
            address += 1
    matrix = [[0] * cols for _ in range(rows)]
    for col in range(0, cols, 4):
        for row in range(rows):
            address = offset + (col // 4) * rows + row
            word = memory.get(address)
            if word is None:
                raise ValueError('Missing or unknown output word at address {}'.format(address))
            for lane in range(4):
                value = (word >> (16 * lane)) & 0xffff
                if value & 0x8000:
                    value -= 0x10000
                if not -128 <= value <= 127:
                    raise ValueError('Output at row {}, column {} is not a final signed INT8 value: {}'
                                     .format(row, col + lane, value))
                matrix[row][col + lane] = value & 0xff
    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(''.join(' '.join('{:02X}'.format(value) for value in row) + '\n'
                                   for row in matrix))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input_mat', required=True)
    parser.add_argument('--output_mat', required=True)
    parser.add_argument('--M', type=int, required=True, help='Rows of the output matrix')
    parser.add_argument('--N', type=int, required=True, help='Columns of the output matrix')
    parser.add_argument('--offset', type=int, default=0, help='Optional starting word address (default: 0)')
    args = parser.parse_args()
    try:
        convert(args.input_mat, args.output_mat, args.M, args.N, args.offset)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
