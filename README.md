# nbodysim-objc
Real-time cosmology simulation for Apple GPUs.

## Features
- ΛCDM cosmology with comoving coordinates
- GPU acceleration via Apple's Metal Shading Language
- Direct particle-particle force computation
- Spherical mass distribution
- Interactive camera controls

## How to use
#### To build:
`xcrun -sdk macosx metal -c shaders.metal -o shaders.air && xcrun -sdk macosx metallib shaders.air -o shaders.metallib && clang++ -std=c++17 -ObjC++ main.mm -o GravitySim -framework Cocoa -framework Metal -framework MetalKit`
#### To run:
`./GravitySim --N [num particles] --z [initial redshift] --dt [time step (Megayears)] --r [initial radius (Megaparsecs)] --soft [softening coefficient]`

Default parameters: N=32768, z=30.0, dt=5.0, r=1.0, soft=0.1
## Controls
- **Scroll and drag** mouse to move the camera
- **Space** to pause/unpause the simulation
- **'r'** to reset the simulation
- **'p'** to print the current state (redshift, momentum, energy)
<img width="2880" height="1694" alt="Screenshot 2026-06-06 at 10 22 16 PM" src="https://github.com/user-attachments/assets/cc73ad31-eaa8-4cf3-a7b6-4db3673c4871" />
