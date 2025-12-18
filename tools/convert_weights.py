import numpy as np
from safetensors.numpy import save_file
import sys
import os

def convert(input_path, output_path):
    print(f"🦄 Converting {input_path} to {output_path}...")
    
    if not os.path.exists(input_path):
        print(f"❌ Input file not found: {input_path}")
        sys.exit(1)
        
    try:
        data = np.load(input_path)
        # Convert NpzFile to dict
        tensors = {k: data[k] for k in data.files}
        
        print(f"   Found {len(tensors)} tensors.")
        if len(tensors) > 0:
            print(f"   Sample key: {list(tensors.keys())[0]}")
            
        save_file(tensors, output_path)
        print("✅ Conversion complete.")
    except Exception as e:
        print(f"❌ Conversion failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python convert_weights.py <input.npz> <output.safetensors>")
        sys.exit(1)
        
    convert(sys.argv[1], sys.argv[2])
