#!/usr/bin/env python3
"""Cycle model of the current 4x4 INT8 RTL: memory, external, and BIST modes."""

import argparse
from collections import deque
from pathlib import Path


def saturate(value, bits):
    return min((1 << (bits - 1)) - 1, max(-(1 << (bits - 1)), value))


def final_result(value, relu=False):
    return saturate(max(0, value) if relu else value, 8)


def pack(values, bits=8):
    return sum((value & ((1 << bits) - 1)) << (lane * bits)
               for lane, value in enumerate(values))


def unpack(word, bits=8):
    values = [(word >> (lane * bits)) & ((1 << bits) - 1) for lane in range(4)]
    return [value - (1 << bits) if value & (1 << (bits - 1)) else value
            for value in values]


def check_matrix(matrix, rows, cols):
    if len(matrix) != rows or any(len(row) != cols for row in matrix):
        raise ValueError(f'Expected a {rows}x{cols} matrix')
    if any(not isinstance(value, int) or not -128 <= value <= 127
           for row in matrix for value in row):
        raise ValueError('Matrix values must be signed INT8 integers')


def read_matrix(path, rows, cols):
    matrix = []
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        row = []
        for token in line.split():
            if len(token) != 2 or any(c not in '0123456789abcdefABCDEF' for c in token):
                raise ValueError(f'{path}: expected two-digit hex bytes')
            value = int(token, 16)
            row.append(value - 256 if value >= 128 else value)
        matrix.append(row)
    check_matrix(matrix, rows, cols)
    return matrix


def write_matrix(path, matrix):
    Path(path).write_text(''.join(' '.join(f'{v & 255:02X}' for v in row) + '\n'
                                for row in matrix))


def make_memory(matrix, offset=0):
    """Four lanes per word; tile columns first, then rows; lane 0 is the LSB."""
    rows, cols = len(matrix), len(matrix[0])
    if cols % 4 or offset < 0 or offset + rows * (cols // 4) > 1024:
        raise ValueError('Matrix and offset must fit the 1024-word memory')
    memory = [0] * 1024
    for col in range(0, cols, 4):
        for row in range(rows):
            memory[offset + (col // 4) * rows + row] = pack(matrix[row][col:col + 4])
    return memory


def next_pattern(state):
    """Updated LFSR uses [63:0] indexing with taps 63, 62, 61, and 52."""
    feedback = ((state >> 63) ^ (state >> 62) ^ (state >> 61) ^ (state >> 52)) & 1
    return ((state << 1) | feedback) & ((1 << 64) - 1)


def next_signature(state):
    """MISR retains [64:1] indexing; its numerical tap positions differ from LFSR."""
    feedback = ((state >> 62) ^ (state >> 61) ^ (state >> 60) ^ (state >> 51)) & 1
    return ((state << 1) | feedback) & ((1 << 64) - 1)


def stop_code(seed, patterns):
    if patterns < 0:
        raise ValueError('Pattern count must be nonnegative')
    for _ in range(patterns):
        seed = next_pattern(seed)
    return seed


class Delay:
    def __init__(self, depths, initial=None):
        self.buffers = [deque([initial] * depth) for depth in depths]

    def step(self, values):
        result = []
        for buffer, value in zip(self.buffers, values):
            buffer.append(value)
            result.append(buffer.popleft())
        return result


class PEArray:
    def __init__(self):
        self.weights = [[0] * 4 for _ in range(4)]
        self.weight_en = [[False] * 4 for _ in range(4)]
        self.activations = [[None] * 4 for _ in range(4)]
        self.psums = [[None] * 4 for _ in range(4)]

    def step(self, activations, weights, weight_en):
        next_acts = [[None] * 4 for _ in range(4)]
        next_psums = [[None] * 4 for _ in range(4)]
        next_en = [[False] * 4 for _ in range(4)]
        for row in range(4):
            for col in range(4):
                enable = weight_en[col] if row == 0 else self.weight_en[row - 1][col]
                next_en[row][col] = enable
                if enable:
                    self.weights[row][col] = weights[col]
                act = activations[row] if col == 0 else self.activations[row][col - 1]
                above = None if row == 0 else self.psums[row - 1][col]
                next_acts[row][col] = act
                if act is None:
                    if above is not None:
                        raise RuntimeError('Partial sum arrived without its activation')
                    continue
                tag, value = act
                if row and (above is None or above[0] != tag):
                    raise RuntimeError('Activation and partial sum are misaligned')
                total = value * self.weights[row][col] + (above[1] if row else 0)
                # Each MAC registers an 18-bit two's-complement partial sum.
                total = ((total + (1 << 17)) & ((1 << 18) - 1)) - (1 << 17)
                next_psums[row][col] = (tag, total)
        self.activations, self.psums, self.weight_en = next_acts, next_psums, next_en
        return next_psums[3]


class Datapath:
    """Shared activation/weight skew, traveling enable, PE array, and result alignment."""
    def __init__(self):
        self.array = PEArray()
        self.act_skew = Delay(range(4))
        self.weight_skew = Delay(range(4), 0)
        self.enable_skew = Delay(range(4), False)
        self.result_align = Delay([3, 2, 1, 0])
        self.valid_pipe = deque([None] * 6)
        self.aligned = None

    @property
    def next_result_tag(self):
        return self.valid_pipe[0]

    def step(self, tag, activations, weights, load_pulse):
        inputs = [None if tag is None else (tag, value) for value in activations]
        outputs = self.array.step(self.act_skew.step(inputs),
                                  self.weight_skew.step(weights),
                                  self.enable_skew.step([load_pulse] * 4))
        aligned = self.result_align.step(outputs)
        self.valid_pipe.append(tag)
        expected = self.valid_pipe.popleft()
        if expected is None:
            if any(value is not None for value in aligned):
                raise RuntimeError('Unexpected aligned result')
            self.aligned = None
        else:
            if any(value is None or value[0] != expected for value in aligned):
                raise RuntimeError('Result columns are misaligned')
            self.aligned = (expected, [value[1] for value in aligned])
        return self.aligned


class Simulator:
    """Memory-mode computation; cycles count COMPUTE edges, excluding reset/start/DONE."""
    def __init__(self, a, b, act_offset=0, wgt_offset=0, rst_offset=0, relu=False,
                 zero_tile=False):
        self.m, self.k = len(a), len(a[0]) if a else 0
        self.n = len(b[0]) if b else 0
        if any(size < 4 or size > 64 or size % 4 for size in (self.m, self.n, self.k)):
            raise ValueError('M, N, and K must be multiples of 4 between 4 and 64')
        check_matrix(a, self.m, self.k)
        check_matrix(b, self.k, self.n)
        self.input_memory = make_memory(a, act_offset)
        self.weight_memory = make_memory(b, wgt_offset)
        if rst_offset < 0 or rst_offset + self.m * (self.n // 4) > 1024:
            raise ValueError('Output and offset must fit the 1024-word memory')
        self.partial_sum_memory = [0] * 1024
        self.act_offset, self.wgt_offset, self.rst_offset = act_offset, wgt_offset, rst_offset
        self.datapath = Datapath()
        self.relu = bool(relu)
        self.zero_tile = bool(zero_tile)
        self.skipped_tiles = 0
        self.compute_cycles = 0
        self.weight_loads = 0
        self.partial_sum_writes = 0
        self.saturation_events = 0
        self.weight_tile_order = []
        self.has_run = False

    def _address(self, tag):
        n_tile, _, row = tag
        return self.rst_offset + n_tile * self.m + row

    def _write(self, pending):
        tag, sums, previous = pending
        _, k_tile, _ = tag
        values = []
        for col, value in enumerate(sums):
            total = value + (previous[col] if k_tile else 0)
            if k_tile == self.k // 4 - 1:
                values.append(final_result(total, self.relu))
            else:
                saved = saturate(total, 16)
                self.saturation_events += saved != total
                values.append(saved)
        self.partial_sum_memory[self._address(tag)] = pack(values, 16)
        self.partial_sum_writes += 1

    def read_output(self):
        output = [[] for _ in range(self.m)]
        for n_tile in range(self.n // 4):
            for row in range(self.m):
                output[row].extend(unpack(self.partial_sum_memory[
                    self.rst_offset + n_tile * self.m + row], 16))
        return output

    def run(self):
        if self.has_run:
            raise ValueError('Create a new Simulator for each multiplication')
        self.has_run = True
        schedule = []
        for nt in range(self.n // 4):
            for kt in range(self.k // 4):
                base = self.wgt_offset + nt * self.k + kt * 4
                skip = (self.zero_tile and self.m > 5 and 0 < kt < self.k // 4 - 1
                        and not any(self.weight_memory[base:base + 4]))
                self.skipped_tiles += skip
                # Four synchronous responses are known at the fifth request edge.
                schedule.extend((nt, kt, row) for row in range(5 if skip else self.m))
        requests = len(schedule)
        request_idx = 0
        response = None
        weight_response = [0] * 4
        pending = None
        while self.partial_sum_writes < requests:
            self.compute_cycles += 1
            # Synchronous SRAM prefetch precedes this row's write by one clock.
            prefetch_tag = self.datapath.next_result_tag
            previous = [0] * 4
            if prefetch_tag is not None and prefetch_tag[1] != 0:
                address = self._address(prefetch_tag)
                if pending is not None and self._address(pending[0]) == address:
                    raise RuntimeError('Output memory read/write collision')
                previous = unpack(self.partial_sum_memory[address], 16)
            if pending is not None:
                self._write(pending)
            tag, activations = response if response is not None else (None, [0] * 4)
            aligned = self.datapath.step(tag, activations, weight_response,
                                         tag is not None and tag[2] == 0)
            pending = None if aligned is None else (*aligned, previous)
            # Read one activation word per clock without draining between tiles.
            if request_idx < requests:
                n_tile, k_tile, row = schedule[request_idx]
                word = self.input_memory[self.act_offset + k_tile * self.m + row]
                response = ((n_tile, k_tile, row), unpack(word))
                if row < 4:
                    address = self.wgt_offset + n_tile * self.k + k_tile * 4 + row
                    weight_response = unpack(self.weight_memory[address])
                    if row == 0:
                        self.weight_loads += 1
                        self.weight_tile_order.append((k_tile, n_tile))
                request_idx += 1
            else:
                response = None
        return self.read_output()


class ExternalSimulator:
    """Each step is one rising clock; None denotes an invalid activation word."""
    def __init__(self, relu=False):
        self.datapath = Datapath()
        self.relu = bool(relu)
        self.weights = [0] * 4
        self.weight_en_d = False
        self.inputs_seen = 0
        self.outputs_seen = 0
        self.cycles = 0
        self.results = []

    @property
    def pending_count(self):
        return self.inputs_seen - self.outputs_seen

    def step(self, activations=None, weights=None, weight_en=False):
        if activations is not None:
            check_matrix([activations], 1, 4)
        if weights is not None:
            check_matrix([weights], 1, 4)
            self.weights = list(weights)
        # Consumers sample the aligned result produced by the previous edge.
        result = None
        if self.datapath.aligned is not None:
            result = [final_result(value, self.relu) for value in self.datapath.aligned[1]]
            self.results.append(result)
            self.outputs_seen += 1
        tag = self.inputs_seen if activations is not None else None
        if tag is not None:
            self.inputs_seen += 1
        self.datapath.step(tag, activations if activations is not None else [0] * 4,
                           self.weights, weight_en and not self.weight_en_d)
        self.weight_en_d = bool(weight_en)
        self.cycles += 1
        return result

    def load_weights(self, weights):
        check_matrix(weights, 4, 4)
        if self.pending_count:
            raise ValueError('Use step() to reload weights while inputs are in flight')
        for row in weights:
            self.step(weights=row, weight_en=True)
        for _ in range(3):
            self.step()

    def drain(self):
        while self.pending_count:
            self.step()
        return self.results


class PatternGenerator:
    def __init__(self, seed, stop):
        if not 0 <= seed < (1 << 64) or not 0 <= stop < (1 << 64):
            raise ValueError('LFSR seed and stop code must fit 64 bits')
        self.word, self.stop = seed, stop
        self.valid = False
        self.state = 'IDLE'

    @property
    def next_state(self):
        if self.state == 'IDLE':
            return 'RUN'
        if self.state == 'RUN' and self.word == self.stop:
            return 'DONE'
        return self.state

    @property
    def done(self):
        return self.next_state == 'DONE'

    def step(self, valid=False):
        state = self.next_state
        self.valid = bool(valid and state == 'RUN')
        if self.valid:
            self.word = next_pattern(self.word)
        self.state = state


class BistSimulator(ExternalSimulator):
    """Wrapper bypass=000, mode=00; weights are supplied externally."""
    def __init__(self, seed, stop, signature_seed=None, relu=False):
        super().__init__(relu=relu)
        self.driver = PatternGenerator(seed, stop)
        self.signature = ((seed & 0xffffffff) << 32) | (seed >> 32)
        if signature_seed is not None:
            if not 0 <= signature_seed < (1 << 64):
                raise ValueError('Signature seed must fit 64 bits')
            self.signature = signature_seed
        self.signature_valid = False
        self.sa_state = 'IDLE'
        self.compressed_results = []

    def step(self, driver_valid=False, weights=None, weight_en=False):
        input_valid = self.driver.valid
        stop = self.driver.done
        state = 'RUN' if self.sa_state == 'IDLE' else ('DONE' if stop else self.sa_state)
        self.signature_valid = state == 'DONE'
        activations = unpack(self.driver.word >> 32) if input_valid else None
        result = super().step(activations, weights, weight_en)
        if result is not None and not self.signature_valid:
            self.compressed_results.append(result)
            self.signature = next_signature(self.signature) ^ pack(result)
        self.sa_state = state
        self.driver.step(driver_valid)
        return self.signature if self.signature_valid else None

    def run(self, weights, valid_pattern=(True,), max_cycles=100000):
        if not valid_pattern or not any(valid_pattern):
            raise ValueError('Valid pattern must contain at least one active clock')
        self.load_weights(weights)
        for cycle in range(max_cycles):
            if self.signature_valid:
                self.drain()
                return self.results
            self.step(driver_valid=valid_pattern[cycle % len(valid_pattern)])
        raise ValueError('BIST stop code was not reached within max_cycles')


def valid_pattern(text):
    if not text or any(c not in '01' for c in text) or '1' not in text:
        raise argparse.ArgumentTypeError('Use a nonempty binary pattern containing 1')
    return tuple(c == '1' for c in text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='mode')
    memory = modes.add_parser('memory', help='Continuous tiled A[M,K] x B[K,N]')
    memory.add_argument('--zero-tile', action='store_true',
                        help='Skip the remaining rows of zero middle-K weight tiles (default: off)')
    for name in ('m', 'n', 'k'):
        memory.add_argument(name, type=int)
    for name in ('a_file', 'b_file', 'c_file'):
        memory.add_argument(name)
    for name in ('act_offset', 'wgt_offset', 'rst_offset'):
        memory.add_argument('--' + name.replace('_', '-'), type=int, default=0)
    external = modes.add_parser('external', help='Externally supplied A[M,4] x B[4,4]')
    external.add_argument('m', type=int)
    for name in ('a_file', 'b_file', 'c_file'):
        external.add_argument(name)
    external.add_argument('--valid-pattern', type=valid_pattern, default=(True,))
    bist = modes.add_parser('bist', help='LFSR activations, external B[4,4], MISR signature')
    bist.add_argument('b_file')
    bist.add_argument('c_file', help='Output rows generated during BIST')
    bist.add_argument('--seed', type=lambda value: int(value, 0), default=0x123456789abcdef0)
    bist.add_argument('--patterns', type=int, default=32)
    bist.add_argument('--valid-pattern', type=valid_pattern, default=(True,))
    for mode in (memory, external, bist):
        mode.add_argument('--relu', action='store_true', help='Enable final ReLU (default: off)')
    args = parser.parse_args()
    if args.mode is None:
        parser.error('Choose memory, external, or bist')
    try:
        if args.mode == 'memory':
            sim = Simulator(read_matrix(args.a_file, args.m, args.k),
                            read_matrix(args.b_file, args.k, args.n),
                            args.act_offset, args.wgt_offset, args.rst_offset, relu=args.relu,
                            zero_tile=args.zero_tile)
            result = sim.run()
            print(f'Compute cycles: {sim.compute_cycles}; weight tiles: {sim.weight_loads}')
        elif args.mode == 'external':
            if args.m < 1:
                raise ValueError('M must be positive')
            a = read_matrix(args.a_file, args.m, 4)
            sim = ExternalSimulator(relu=args.relu)
            sim.load_weights(read_matrix(args.b_file, 4, 4))
            row, cycle = 0, 0
            while row < args.m:
                valid = args.valid_pattern[cycle % len(args.valid_pattern)]
                sim.step(a[row] if valid else None)
                row += valid
                cycle += 1
            result = sim.drain()
            print(f'Input rows: {sim.inputs_seen}; output rows: {sim.outputs_seen}')
        else:
            sim = BistSimulator(args.seed, stop_code(args.seed, args.patterns), relu=args.relu)
            result = sim.run(read_matrix(args.b_file, 4, 4), args.valid_pattern,
                             max_cycles=(args.patterns + 1) * len(args.valid_pattern) + 32)
            if sim.inputs_seen != args.patterns:
                raise ValueError('The seed/stop code ended BIST before the requested pattern count')
            print(f'Stop code: {sim.driver.stop:016X}; signature: {sim.signature:016X}')
        write_matrix(args.c_file, result)
    except (OSError, ValueError) as error:
        parser.exit(2, f'error: {error}\n')


if __name__ == '__main__':
    main()
