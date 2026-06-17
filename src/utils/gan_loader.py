import re
from typing import Sequence, Union
import pandas as pd
import numpy as np
import pickle
import caliperpy
import os
import torch
import torch.nn as nn
import torch.nn.functional as F
import yaml
import openmatrix as omx

# This is for testing
import logging

context = caliperpy.ScriptContext(PythonContext if caliperpy.IsInProcess() else None)

def write_omx(filename, tag, data):
    omx_file = omx.open_file(filename, 'w')
    omx_file[tag] = data
    omx_file.close()

class ResBlock(nn.Module):
    def __init__(self, dim, dropout=0.1):
        super().__init__()
        self.block = nn.Sequential(
            nn.LayerNorm(dim),
            nn.Linear(dim, dim),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(dim, dim),
            nn.Dropout(dropout),
        )

    def forward(self, x):
        return x + self.block(x)

class Generator(nn.Module):
    """
    B = Batch size
    J = Destination zones
    K = Employment Categories

    Inputs:
        - Vector:
            - skim data (probably time) (B, J)
            - Employment data (B, J * K)
        - Hidden dim
        - Dropout probability
    """
    def __init__(
        self,
        input_dim: int,
        output_dim: int,
        hidden_dim: int = 128,
        dropout: float = 0.1,
        depth: int = 3,
    ):
        super().__init__()
        self.num_outcomes = output_dim
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.inp = nn.Linear(input_dim, hidden_dim)
        self.blocks = nn.Sequential(*[ResBlock(hidden_dim, dropout) for _ in range(depth)])
        self.out = nn.Sequential(nn.LayerNorm(hidden_dim), nn.Linear(hidden_dim, output_dim))
        self._initialize_weights()

    def _initialize_weights(self):
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.xavier_uniform_(m.weight)
                if m.bias is not None:
                    nn.init.constant_(m.bias, 0.0)

    def forward(self, data_vect: torch.Tensor) -> torch.Tensor:
        n = self.inp(data_vect)
        n = self.blocks(n)
        return self.out(n)

def load_model(model_path, generator_class, model_config):
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    checkpoint = torch.load(model_path, map_location=device, weights_only=False)
    generator = generator_class(**model_config).to(device)
    if isinstance(checkpoint, dict):
        if 'G_state_dict' in checkpoint:
            generator.load_state_dict(checkpoint['G_state_dict'])
        elif 'model_state_dict' in checkpoint:
            generator.load_state_dict(checkpoint['model_state_dict'])
        else:
            generator.load_state_dict(checkpoint)
    else:
        generator.load_state_dict(checkpoint)
    generator.eval()
    return generator, device

def main(**kwargs):
    # BIG IMPORTANT NOTE
    # This is all custom to Reno and the ML models used with Reno. This should not
    # be assumed to be something that can be template or cookie-cutter.

    # Constants
    PERIODS = {0: 'EA', 1: 'AM', 2: 'MD', 3: 'PM', 4: 'NT'}
    period_id2N = {v:k for k, v in PERIODS.items()}
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    # Setup logger    
    
    file_handler = logging.FileHandler(os.path.join(kwargs['output_folder'], f"gan_loader_log.txt"))
    file_handler.setLevel(logging.INFO)
    formatter = logging.Formatter('[%(asctime)s][%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    file_handler.setFormatter(formatter)
    # logger = logging.getLogger(__name__)
    logger = logging.getLogger(kwargs['tag'])
    if logger.hasHandlers():
        logger.handlers.clear() 
    logger.propagate = False
    logger.setLevel(logging.INFO)
    logger.addHandler(file_handler)
    logger.info(f"Starting process... tag = {kwargs['tag']} pid = {os.getpid()}")

    # 0. Connect to TransCAD
    dk = caliperpy.TransCAD.connect(log_file = os.path.join(kwargs['output_folder'], "a_python.log"))
    # 1. Get, sort, index, and normalize sedata
    try:
        sedata = dk.GetDataFrameFromBin(kwargs['se_file']).sort_values('TAZ') 
        sedata['taz_idx'] = np.arange(0, sedata.shape[0])
        sedata['taz'] = sedata['TAZ']
        taz_idx_labels = np.array(sedata['TAZ'])
        # view_for_index = sedata[['taz_idx', 'TAZ']].copy()
        # view_for_index['taz_idx'] = view_for_index['taz_idx'] + 1
        # # view_for_index.reset_index(inplace = True)
        # dk.WriteBinFromDataFrame(view_for_index, os.path.join(kwargs['output_folder'], 'tempvw.bin'))
        taz = dk.GetDataFrameFromBin(kwargs['taz file']).sort_values('TAZ')
        sedata = sedata[sedata['Type'] == 'Internal'].copy()
        sedata = sedata.merge(taz[['TAZ', 'DISTRICT']], how = 'left', on = 'TAZ')
        # Normalize data fields
        sedata['hh'] = np.log1p(sedata['HH'].fillna(0)) / np.log1p(sedata['HH'].fillna(0)).max()
        sedata['emp_retail'] = np.log1p(sedata['Retail'].fillna(0)) / np.log1p(sedata['Retail'].fillna(0)).max()
        sedata['emp_office'] = np.log1p(sedata['Office'].fillna(0)) / np.log1p(sedata['Office'].fillna(0)).max()
        sedata['emp_service'] = np.log1p(sedata['Service_RateHigh'].fillna(0) + sedata['Service_RateLow'].fillna(0)) / np.log1p(sedata['Service_RateHigh'].fillna(0) + sedata['Service_RateLow'].fillna(0)).max()
        sedata['hotelrms'] = np.log1p(sedata['HotelRms'].fillna(0)) / np.log1p(sedata['HotelRms'].fillna(0)).max()
        sedata['district'] = sedata['DISTRICT'].fillna(0)
        sedata = sedata[['taz', 'taz_idx', 'district', 'hh', 'emp_retail', 'emp_office', 'emp_service', 'hotelrms']].copy()
        if logger.level == logging.DEBUG:
            sedata.to_csv(os.path.join(kwargs['output_folder'], "sedata_debug.csv"), index = False)
        for d in sedata['district'].unique():
            sedata[f'district_{d}'] = 0
            sedata.loc[sedata['district'] == d, f'district_{d}'] = 1
        logger.debug("SEDATA processing completed")
    except Exception as e:
        logger.error("Error in SEDATA Processing!")
        logger.error(e)
        logging.getLogger().handlers.clear()
        return False    
    logger.debug("SEDATA loaded and prepared")

    # 2. Get, sort, and index, and normalize skim data
    try:
        # skim_matrix = dk.OpenMatrix(kwargs['skim_file'], "True")
        # skim_currency = dk.CreateMatrixCurrency(skim_matrix, kwargs['Skim table'], None, None, None)
        # logger.info(f"skim currency: {skim_currency}")
        # skim = np.array(dk.GetMatrixValues(skim_currency, None, None), dtype = np.float32)
        logger.debug(f"Opening skim: {kwargs['skim_file']}")
        skim_file = omx.open_file(kwargs['skim_file'], 'r')
        logger.debug(f"Skim file contents: {skim_file.list_matrices()}")
        skim_in = np.array(skim_file['CongTime'], dtype = np.float32)
        logger.debug(f"Skim 1-> 2 = {skim_in[1, 2]}")
        logger.debug(f"Skim 1-> 738 = {skim_in[1, 738]}")
        skim_file.close()
        logger.info(f"Skim shape: {skim_in.shape}")
        skim = np.nan_to_num(skim_in)
        skim[:] = np.maximum(np.minimum(skim, 100),0)
        skim[:] = np.log1p(skim) / np.log1p(skim).max()
        if logger.level == logging.DEBUG:
            skim_debug_output_omx = omx.open_file(os.path.join(kwargs['output_folder'], "skim_debug.omx"), 'w')
            skim_debug_output_omx['skim_in'] = skim_in
            skim_debug_output_omx['norm_skim'] = skim
            skim_debug_output_omx['log1p_skim'] = np.log1p(skim_in)
            skim_debug_output_omx['skim_nan_rm'] = np.nan_to_num(skim_in)
            skim_debug_output_omx.close()
        logger.debug(f"Skim normalized 1-> 2 = {skim[1, 2]}")
        skim_o_shape = skim.shape
        skim = skim[0:sedata.shape[0], 0:sedata.shape[0]]
        # transform 
    except Exception as e:
        logger.error("Error in skim processing!")
        logger.error(e)
        logging.getLogger().handlers.clear()
        return False
    logger.debug("Skim data loaded and prepared")

    # 3. Load Model File
    yaml_path = kwargs['parameter_file'].replace('%Input Folder%', kwargs['Input Folder'])
    param_array_in = yaml.load(open(yaml_path), Loader = yaml.SafeLoader)
    param_array = {
        "output_dim": param_array_in['output_dim'],
        "input_dim": param_array_in['input_dim'],
        "hidden_dim": param_array_in['hidden'],
        "dropout": param_array_in['dropout'],
        "depth": param_array_in['depth'],
        }
    gan_model_file = kwargs['model_file'].replace('%Input Folder%', kwargs['Input Folder'])

    # 4. Prepare data for GAN - skims then SE
    matx = np.zeros((len(PERIODS), skim.shape[0], skim.shape[1]), dtype=np.float32)
    for k in PERIODS.keys():
        matx[k] = skim
    matx_torch = torch.as_tensor(matx, device=device, dtype=torch.float32)

    period_idx = np.ones(skim.shape[0]) * period_id2N[kwargs['period']]

    orig_feats_torch = torch.as_tensor(np.array(sedata[param_array_in['ose_cols']], dtype = np.float32), device=device, dtype=torch.float32)
    dest_feats_torch = torch.as_tensor(np.array(sedata[param_array_in['dse_cols']], dtype = np.float32).flatten('F'), device=device, dtype=torch.float32) 

    origin_idx = torch.as_tensor(np.arange(0, sedata.shape[0]), device = device, dtype=torch.int64)
    cost_mtx = matx_torch[period_idx, origin_idx, :]

    # Build an intrardistrict matrix
    if param_array_in['build_intradistrict_matrix_field'] != 'None':
        if not param_array_in['build_intradistrict_matrix_field'] in sedata.columns:
            raise RuntimeError(f"Field {param_array_in['build_intradistrict_matrix_field']} not in sedata!")
        interdist_mtx = torch.zeros_like(matx_torch[0])
        for d in sedata[param_array_in['build_intradistrict_matrix_field']]:
            taz_idxs = sedata[sedata[param_array_in['build_intradistrict_matrix_field']] == d]['taz_idx'] 
            for i in taz_idxs:
                for j in taz_idxs:
                    interdist_mtx[int(i), int(j)] = 1

    # Build an intrazonal matrix
    if param_array_in['use_intrazonal']:
        intrazonal_mtx = torch.zeros_like(matx_torch[0], dtype=torch.int)
        intrazonal_mtx.fill_diagonal_(1)
    
    # Build the rest of the data
    if not param_array_in['ose_cols'] is None and not param_array_in['dse_cols'] is None:
        orig_data = orig_feats_torch[origin_idx]
        emp_data = dest_feats_torch.unsqueeze(0).expand(sedata.shape[0], -1)
        emp_data = torch.cat([orig_data, emp_data], dim = 1)
    elif not param_array_in['ose_cols'] is None:
        ctx_data = torch.as_tensor(F.one_hot(period_idx, num_classes = len(PERIODS)), device = device, dtype = torch.float32)
        if not param_array_in['ose_cols'] is None:
            orig_atts = torch.as_tensor(sedata[param_array_in['ose_cols']], device = device, dtype = torch.float32)
            ctx_data = torch.cat((ctx_data, orig_atts), dim = 1)
    elif not param_array_in['dse_cols'] is None:
        emp_data = dest_feats_torch.unsqueeze(0).expand(sedata.shape[0], -1)

    dv = torch.cat([cost_mtx, emp_data], dim = 1)
    if param_array_in['build_intradistrict_matrix_field'] != 'None':
        idmtx = interdist_mtx[origin_idx, :]
        dv = torch.cat([dv, idmtx], dim = 1)
    if param_array_in['use_intrazonal']:
        izmtx = intrazonal_mtx[origin_idx, :]
        dv = torch.cat([dv, izmtx], dim = 1)

    try:
        generator, device = load_model(
            gan_model_file,
            Generator,
            param_array
        )
        generator.eval()
        with torch.inference_mode():
            gen_util = generator(dv) #.detach().numpy()
        gen_util_out = gen_util.detach().numpy()
        logger.debug("Generator loaded.")
        logger.debug(f"gen_util shape: {gen_util.shape} - type = {gen_util.dtype}")
        logger.debug(f"Generator 1 -> 2 = {gen_util[0,1]}")
        logger.debug(f"dk = {dk}")
    except Exception as e:
        logger.error("Error in generator loading")
        logger.exception("An error occurred during calculation")
        logging.getLogger().handlers.clear()
        return False
    
    try:
        gan_output_file = os.path.join(kwargs['output_folder'], f"gen_{kwargs['tag']}.omx")
        out_file = omx.open_file(gan_output_file, 'w') # 'r' = read, 'w' is write
        out_mtx = np.pad(gen_util_out, ((0, taz_idx_labels.shape[0] - gen_util_out.shape[0]), (0, taz_idx_labels.shape[0] - gen_util_out.shape[1])), mode='constant', constant_values=0) 
        #TODO: test above line with NA instead of 0... the NA values may be polluting the output due to exp (check TransCAD to see what I am doing there)
        logger.info(f"(line 279) out_mtx shape = {out_mtx.shape}")
        out_file['gan_utils'] = out_mtx
        out_file.create_mapping('Rows', taz_idx_labels)
        out_file.create_mapping('Columns', taz_idx_labels)
        
        # gan_output_file = os.path.join(kwargs['output_folder'], f"gen_{kwargs['tag']}.mtx")
        # mtx_specs = {
        #     'File Name': gan_output_file,
        #     'Label': "testing",
        #     'Tables': ['gan_utils']
        # }
        # logger.debug(f"skim_o_shape={skim_o_shape}")
        # t_mtx = dk.CreateSimpleMatrix(kwargs['tag'], skim_o_shape[0], skim_o_shape[1], mtx_specs)
        # logger.debug("mtx created")
        # vw = dk.OpenTable('view', 'FFB', [os.path.join(kwargs['output_folder'], 'tempvw.bin'), None])
        # logger.debug("vw opened")
        # mc = dk.CreateMatrixCurrency(t_mtx, 'gan_utils', "Row Index", "Column Index", None)
        # logger.debug("currency created")
        # dk.SetMatrixValues(mc, np.arange(1, gen_util_out.shape[0] + 1), np.arange(1, gen_util_out.shape[1] + 1), ['Copy', gen_util_out], None)
        # dk.CreateMatrixIndex("Rows", t_mtx, "Rows", vw + "|", 'taz_idx', 'TAZ')
        # dk.CreateMatrixIndex("Columns", t_mtx, "Columns", vw + "|", 'taz_idx', 'TAZ')
        logger.debug(f"Generated output to be written to {gan_output_file}")
    except Exception as e:
        logger.error("Error in matrix write")
        logger.exception("An error occurred during matrix write")
        logging.getLogger().handlers.clear()
        return False   
    finally:
        out_file.close()
        # dk.CloseView(vw)
    logging.getLogger().handlers.clear()
    return True

if __name__ in ["__main__", "__ax_main__"]:
    result = context.run(locals())
