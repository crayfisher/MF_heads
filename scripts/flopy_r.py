import flopy
import numpy as np
import flopy.utils.binaryfile as bf
import pandas as pd

def get_lst_py(file):
  mf_list = flopy.utils.MfListBudget(file)
  
  kstpkper = mf_list.get_kstpkper()
  kstpkper_df = pd.DataFrame(kstpkper)
  kstpkper_df.columns = ['kstp','kper']
  
  times = mf_list.get_times()
  times_df = pd.DataFrame(times)
  times_df.columns = ['totim']
 
  
  incrementaldf, cumulativedf = mf_list.get_dataframes()
  incrementaldf.reset_index(level=0, inplace=True)
  incrementaldf = pd.concat([kstpkper_df,times_df,incrementaldf],axis=1)
  incrementaldf.rename(columns={'index':'time'}, inplace=True)

  return(incrementaldf)
  
  
def get_alldata_usg(hdobj):
  nlay = hdobj.nlay
  times = hdobj.get_times()
  nSP = len(times)
  
  layer_data = []
  for lay in range(nlay):
    layer_data.append(hdobj.get_alldata(mflay=lay))
      
  shapes = [d.shape[1] for d in layer_data]
  if len(set(shapes)) == 1:
    return np.stack(layer_data, axis=1)
  else:
    arr = np.empty((nSP, nlay), dtype=object)
    for sp in range(nSP):
      for lay in range(nlay):
        arr[sp, lay] = layer_data[lay][sp]
    return arr

def get_head(file,header = "HEADU"):
  hdobj = bf.HeadUFile(file,text = header)
  usgheads = get_alldata_usg(hdobj)
  return(usgheads)
  
def get_drd(file,header = "DRAWDOWNU"):
  hdobj = bf.HeadUFile(file,text = header)
  usgheads = get_alldata_usg(hdobj)
  return(usgheads)  


# “HEADU”,
# “DRAWDOWNU”,
# “CLN HEADS”, or
# “CLN DRAWDOWN”  
#seems to work fo gw nodes, but not for cln cells  
  
  
  
  
  
def get_head_times(file,header = "headu"):
  hdobj = bf.HeadUFile(file,text = header)
  kstpkper = hdobj.get_kstpkper()
  times = hdobj.get_times() 
  steps = hdobj.get_kstpkper()
  steps1 = np.array(steps)
  times = hdobj.get_times()
  times1 = np.array(times)
  combined = np.vstack((times1,steps1[:,0],steps1[:,1]))
  combined = np.transpose(combined)
  return(combined)
  
def get_drd_times(file,header = "DRAWDOWNU"):
  hdobj = bf.HeadUFile(file,text = header)
  kstpkper = hdobj.get_kstpkper()
  times = hdobj.get_times() 
  steps = hdobj.get_kstpkper()
  steps1 = np.array(steps)
  times = hdobj.get_times()
  times1 = np.array(times)
  combined = np.vstack((times1,steps1[:,0],steps1[:,1]))
  combined = np.transpose(combined)
  return(combined)  
  
  
def get_con_str(file):
  ucnobj= bf.UcnFile(file)
  ucndata = get_alldata_usg(ucnobj)
  return(ucndata)
  
def get_ucn_str_times(file):
  ucnobj = bf.UcnFile(file)
  kstpkper = ucnobj.get_kstpkper()
  times = ucnobj.get_times() 
  steps = ucnobj.get_kstpkper()
  steps1 = np.array(steps)
  times = ucnobj.get_times()
  times1 = np.array(times)
  combined = np.vstack((times1,steps1[:,0],steps1[:,1]))
  combined = np.transpose(combined)
  return(combined)
  
def get_con_u(file,header = "" ):
  hdobj = bf.HeadUFile(file,text = header)
  usgheads = get_alldata_usg(hdobj)
  return(usgheads)
  
def get_times_u(file,header = ""):
  hdobj = bf.HeadUFile(file,text = header)
  kstpkper = hdobj.get_kstpkper()
  times = hdobj.get_times() 
  steps = hdobj.get_kstpkper()
  steps1 = np.array(steps)
  times = hdobj.get_times()
  times1 = np.array(times)
  combined = np.vstack((times1,steps1[:,0],steps1[:,1]))
  combined = np.transpose(combined)
  return(combined)

