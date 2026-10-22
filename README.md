ECE8804
spark3100@gatech.edu
Sang Min Park

1. 
Added pe, input scheduler, weight scheduler, result scheduler modules and intergrated them in matrix_mult.v
Input(Activation), Weight all go into PE at the same time.
For weight setting, only enable signal is shifted down the PEs.

For pes in the same column, weight input is the same straight from weight scheduler. 
But only enable signal(1cycle for each column, skew applied and comes from north) is shifted,
so weight could be saved in correct manner and allows concurrent execution of matrix multiplication 
without having to wait for weight to be fully loaded across all pes. 

step1. pe00 
step2. pe00 pe01
       pe10
step3. pe00 pe01 pe02
       pe10 pe11
       pe20

Like the above order, weight is loaded and at the same time activation propagates to the right,
and psum is accumulated going south.

cf.
PE00 PE01 PE02 PE03 
PE10 PE11 PE12 PE13
PE20 PE21 PE22 PE23
PE30 PE31 PE32 PE33

input scheduler, weight scheduler, result_scheduler all have similar structure.
They have buffers to align the input, weight and result.

Counter has been used to control the operation,
as using fsm(only for start,compute,done) for compute seemed more complicated.
Tiling has been somewhat considered. 
Thought this structure would not have to wait when switching to next tile computation. 

2. For testbench readmem reads the data into memory and computation begins and when done, it compares the result.
   Besides given matrix, 
   1) postive max matrix  * positive max matrix
   2) positive max matrix * negative minimum matrix
   3) just general matrix multiplication 
   could be tested. 

3. A,B memory layout is the same as in the provided example. 

4. The output memory layout is the same as in the provided example.

5. Used ai first for visualizing how the computation works as time progresses like step1, step2, step3...
   
   Using this, found the pattern and realized I needed input/weight/result scheduler to keep the calculation going without stall. So after visualizing the steps, micro arch design was on my own. 

   While implementing, for some syntaxes I used ai to look up how efficiently I could implement.
   - genvar in matrix_mult to instantiate multiple pes withouth code becoming too long
   - used ai to find max/min value when having parameters, so that clipping could work well
   - for testbench I used it for readmem purpose and valueplusargs...
   - used ai to generate max/min test cases so I could test saturation
   - organizing my codes to look clean, code review
   - used ai to check how to do with unused signals for memory

6. The testbench prints PASS if all elements match. Below description was using ai.

```tcsh
mkdir -p sim/behav
cd sim/behav
make -f ../../src/Makefiles/Makefile_sim_presyn link_src
```

Compile the testbench and RTL to create the simulation executable, `simv`:

```tcsh
vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_matrix_mult -f tb_matrix_mult.include -o simv
```

Run the provided example:

```tcsh
./simv +DATA_DIR=../../src/verilog/tests/example
```

Run the additional tests:

```tcsh
./simv +DATA_DIR=../../src/verilog/tests/general
./simv +DATA_DIR=../../src/verilog/tests/positive_max
./simv +DATA_DIR=../../src/verilog/tests/negative_min
```

*no additional features implemented. just 4*4. no tiling.

## Starter code

This project builds on the ECE systolic-array project starter repository at https://github.gatech.edu/ECE-4804-F22/project_systolic. The supplied package, memory models, testbench scaffold, Makefile, and example test data are retained with the student implementation.
