import sys
import os
import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from flopy_r import get_con_u, get_times_u

def convert_hds_to_parquet(hds_file, out_file=None):
    print(f"Reading {hds_file}...")
    
    # Get times/stress periods
    times_arr = get_times_u(hds_file)
    # times_arr is [totim, kstp, kper]
    n_sp = times_arr.shape[0]
    
    # Save times to a separate CSV for the UI
    base, ext = os.path.splitext(hds_file)
    times_file = base + "_times.csv"
    times_df = pd.DataFrame(times_arr, columns=['time', 'kstp', 'kper'])
    times_df['SP'] = np.arange(1, n_sp + 1)
    times_df.to_csv(times_file, index=False)
    print(f"Saved times lookup to {times_file}")
    
    # Get head data
    h_matr = get_con_u(hds_file)
    
    records = []
    
    is_object_array = h_matr.dtype == object
    n_lay = h_matr.shape[1]
    
    print(f"Found {n_sp} Stress Periods, {n_lay} Layers.")
    print("Flattening data into tabular format...")
    
    for sp_idx in range(n_sp):
        sp = sp_idx + 1 # 1-based stress period
        for lay_idx in range(n_lay):
            lay = lay_idx + 1 # 1-based layer
            
            if is_object_array:
                heads = h_matr[sp_idx, lay_idx]
                if isinstance(heads, list):
                    heads = heads[0]
            else:
                heads = h_matr[sp_idx, lay_idx, :]
                
            n_nodes = len(heads)
            
            # Create a dataframe for this chunk
            df_chunk = pd.DataFrame({
                'SP': sp,
                'layer': lay,
                'nodenumberL1': np.arange(1, n_nodes + 1),
                'h': heads
            })
            records.append(df_chunk)
            
    # Combine all chunks
    df = pd.concat(records, ignore_index=True)
    
    # Optimize data types
    df['SP'] = df['SP'].astype(np.uint16)
    df['layer'] = df['layer'].astype(np.uint8)
    df['nodenumberL1'] = df['nodenumberL1'].astype(np.uint32)
    df['h'] = df['h'].astype(np.float32)
    
    if out_file is None:
        out_file = base + ".parquet"
        
    print(f"Writing to {out_file}...")
    table = pa.Table.from_pandas(df)
    pq.write_table(table, out_file, compression='snappy')
    
    print(f"Success! Saved {len(df)} rows to {out_file}.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python convert_hds_to_parquet.py <path_to_hds_file> [output_parquet_file]")
        sys.exit(1)
        
    infile = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else None
    
    convert_hds_to_parquet(infile, outfile)
