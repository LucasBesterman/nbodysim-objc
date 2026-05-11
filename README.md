# nbodysim-objc
Direct N-body simulation of ΛCDM cosmology, utilizing GPU parallel processing.

#### To compile:
`xcrun -sdk macosx metal -c shaders.metal -o shaders.air && xcrun -sdk macosx metallib shaders.air -o shaders.metallib && clang++ -std=c++17 -ObjC++ main.mm -o GravitySim -framework Cocoa -framework Metal -framework MetalKit`
#### To run:
`./GravitySim`
