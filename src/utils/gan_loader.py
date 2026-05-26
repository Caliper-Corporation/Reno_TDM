import re
from typing import Sequence, Union
import pandas as pd
import numpy as np
import pickle
import caliperpy
import os
import torch
import torch.nn.functional as F

# from od_gan_w2_destcond import load_time_dataframe_periodic
# from od_gan_w2_destcond import load_socio_dataframe
# from od_gan_w2_destcond import prepare_destination_socio_features
# from od_gan_w2_destcond import BigGenerator as Generator

# from apply_gan import compute_od_distributions
import yaml

# This is for testing
import logging

context = caliperpy.ScriptContext(PythonContext if caliperpy.IsInProcess() else None)

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

def compute_od_distributions(
    generator: torch.nn.Module,
    origin_indices: Union[Sequence[int], np.ndarray],
    period_indices: Union[int, Sequence[int], np.ndarray],
    time_matrix: np.ndarray,
    dest_socio_features: np.ndarray,
    interdist_mtx: np.ndarray = None,
    intrazonal_mtx: np.ndarray = None,
    device: Union[str, torch.device, None] = None,
) -> np.ndarray:
    generator.eval()

    if device is None:
        try:
            device = next(generator.parameters()).device
        except StopIteration:
            device = torch.device("cpu")
    else:
        device = torch.device(device)

    origin_indices = np.asarray(origin_indices, dtype=np.int64)
    time_matrix = np.asarray(time_matrix, dtype=np.float32)

    B = origin_indices.shape[0]

    if isinstance(period_indices, (int, np.integer)):
        period_indices = np.full(B, int(period_indices), dtype=np.int64)
    else:
        period_indices = np.asarray(period_indices, dtype=np.int64)
        if period_indices.shape[0] != B:
            raise ValueError(
                f"period_indices length {period_indices.shape[0]} "
                f"does not match origin_indices length {B}"
            )    
    distance_dist_np = time_matrix[period_indices, origin_indices, :]  # [B, n_dests]
    distance_dist = torch.as_tensor(distance_dist_np, device=device, dtype=torch.float32)
    emp_data = torch.as_tensor(dest_socio_features, device = device, dtype=torch.float32)

    dv = torch.cat([distance_dist, emp_data], dim = 1)
    if not interdist_mtx is None:
        idmtx = interdist_mtx[origin_indices, :]
        dv = torch.cat([dv, idmtx], dim = 1)
    if not intrazonal_mtx is None:
        izmtx = intrazonal_mtx[origin_indices, :]
        dv = torch.cat([dv, izmtx], dim = 1)

    with torch.no_grad():
        output = generator(data_vect = dv)
    
    return output.cpu()

def main(**kwargs):
    # BIG IMPORTANT NOTE
    # This is all custom to Reno and the ML models used with Reno. This should not
    # be assumed to be something that can be template or cookie-cutter.

    # Setup logger    
    file_handler = logging.FileHandler(os.path.join(kwargs['output_folder'], f"gan_loader_log.txt"))
    file_handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter('[%(asctime)s][%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    file_handler.setFormatter(formatter)
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.DEBUG)
    logger.addHandler(file_handler)
    logger.info(f"Starting process... tag = {kwargs['tag']}")

    # 0. Connect to TransCAD
    dk = caliperpy.TransCAD.connect()
    # 1. Get, sort, index, and normalize sedata
    try:
        sedata = dk.GetDataFrameFromBin(kwargs['se_file']).sort_values('TAZ') 
        sedata = sedata[sedata['Type'] == 'Internal'].copy()
        sedata['taz_idx'] = np.arange(0, sedata.shape[0])
        # Normalize data fields
        sedata['taz'] = sedata['TAZ']
        sedata['hh'] = np.log1p(sedata['HH']) / np.log1p(sedata['HH']).max()
        sedata['emp_retail'] = np.log1p(sedata['Retail']) / np.log1p(sedata['Retail']).max()
        sedata['emp_office'] = np.log1p(sedata['Office']) / np.log1p(sedata['Office']).max()
        sedata['emp_service'] = np.log1p(sedata['Service_RateHigh'] + sedata['Service_RateLow']) / np.log1p(sedata['Service_RateHigh'] + sedata['Service_RateLow']).max()
        sedata['hotelrms'] = np.log1p(sedata['HotelRms']) / np.log1p(sedata['HotelRms']).max()
        sedata['district'] = sedata['Cluster']
        sedata = sedata[['taz', 'taz_idx', 'district', 'hh', 'emp_retail', 'emp_office', 'emp_service', 'hotelrms']].copy()
        for d in sedata['district'].unique():
            sedata[f'district_{d}'] = 0
            sedata.loc[sedata['district'] == d, f'district_{d}'] = 1
    except Exception as e:
        logger.error("Error in SEDATA Processing!")
        logger.error(e)    
    logger.info("SEDATA loaded and prepared")

    # 2. Get, sort, and index, and normalize skim data
    try:
        skim_matrix = dk.OpenMatrix(kwargs['skim_file'], "True")
        skim_currency = dk.CreateMatrixCurrency(skim_matrix, kwargs['Skim table'], None, None, None)
        skim = np.array(dk.GetMatrixValues(skim_currency, None, None), dtype = np.float32)
        skim[:] = np.log1p(skim) / np.log1p(skim).max()
        # transform 
    except Exception as e:
        logger.error("Error in skim processing!")
        logger.error(e)
    logger.info("Skim data loaded and prepared")

    # 3. Load Model File
    yaml_path = kwargs['parameter_file'].replace('%Input Folder%', kwargs['Input Folder'])
    logger.info(f"yaml_path = {yaml_path}")
    param_array = yaml.load(open(yaml_path), Loader = yaml.SafeLoader)
    logger.info(param_array)
    # param_array = 
    # {'od_path': 'data\\sro_train\\cv_sro_train.csv', 'test_od_path': 'data\\sro_test\\cv_sro_test.csv', 
    # 'dist_path': 'data\\dist_skim.csv', 'time_path': 'data\\skims.csv', 'socio_path': 'data\\sedata.csv', 
    # 'epochs': 1000, 'batch_size': 32, 'glr': 0.001, 'dlr': 0.0001, 'hidden': 64, 
    # 'save_dir': './outputs/hbsro_train_105', 'ose_cols': ['district_1', 'district_2', 'district_3', 
    # 'district_4', 'district_5', 'district_6', 'district_7', 'district_8', 'district_9', 'district_10', 
    # 'district_11', 'district_12', 'district_13', 'district_14', 'district_15', 'district_16', 
    # 'district_17', 'district_18', 'district_19', 'district_20', 'district_21', 'district_22', 
    # 'district_23', 'district_24', 'district_25', 'district_26', 'district_27', 'district_28', 
    # 'district_29', 'district_30', 'district_31'], 'dse_cols': ['hh', 'emp_office', 'emp_retail', 
    # 'emp_service', 'district_1', 'district_2', 'district_3', 'district_4', 'district_5', 'district_6', 
    # 'district_7', 'district_8', 'district_9', 'district_10', 'district_11', 'district_12', 'district_13', 
    # 'district_14', 'district_15', 'district_16', 'district_17', 'district_18', 'district_19', 
    # 'district_20', 'district_21', 'district_22', 'district_23', 'district_24', 'district_25', 
    # 'district_26', 'district_27', 'district_28', 'district_29', 'district_30', 'district_31'], 
    # 'dest_embed_dim': 1194, 'depth': 4, 'lambda_w2': 0.0, 'lambda_cel': 1.0, 'use_wandb': 1, 
    # 'wandb_project_name': 'od-gan-hbsro', 'build_intradistrict_matrix_field': 'district', 
    # 'use_intrazonal': True, 'sinkhorn_epsilon': 2.0, 'val_split': 0.15, 'sinkhorn_iters': 200, 
    # 'sinkhorn_tol': 1e-06, 'grad_accum_steps': 1, 'dropout': 0.1, 'input_dim': 44263, 'output_dim': 1164}
    gan_model_file = kwargs['model_file'].replace('%Input Folder%', kwargs['Input Folder'])
    logger.info(f"gan_model_file = {gan_model_file}")

    # time_long_df = load_time_dataframe_periodic(r'C:\models\FHWA_AI_DC\WGAN\data\skims.csv')
    # time_long_df['origin_taz'] = time_long_df['origin_taz'] - 1
    # time_long_df["dest_taz"] = time_long_df["dest_taz"] - 1

    # matx = np.zeros((len(PERIODS), time_long_df['origin_taz'].nunique(), time_long_df['dest_taz'].nunique()), dtype=np.float32)
    # matx[time_long_df['period'].map(PERIOD_TO_IDX), time_long_df['origin_taz'], time_long_df["dest_taz"]] = time_long_df['time']
    # matx[:] = np.log1p(matx) / np.log1p(matx).max()


    # socio_df = load_socio_dataframe(r'C:\models\FHWA_AI_DC\WGAN\data\sedata.csv')
    # taz_to_idx = {a: a-1 for a in np.arange(1, 1165)}

    # trip_origin_period = pd.DataFrame({'origin_taz': [v for v in taz_to_idx.values() for _ in range(len(PERIODS))],
    #                                     'period_idx': [v for v in PERIOD_TO_IDX.values()] * len(taz_to_idx)})
    # MODEL_FOLDER = rf'C:\models\FHWA_AI_DC\WGAN\outputs\hbsro_train_105'
    # config = yaml.load(open(os.path.join(MODEL_FOLDER, 'model_setup.yaml')), Loader = yaml.SafeLoader)

    # param_array = {
    #     "output_dim": config['output_dim'],
    #     "input_dim": config['input_dim'],
    #     "hidden_dim": config['hidden'],
    #     "dropout": config['dropout'],
    #     "depth": config['depth'],
    #     }

    # generator, device = load_model(
    #     os.path.join(MODEL_FOLDER, 'best_model.pt'),
    #     Generator,
    #     param_array
    # )
    # matx_torch = torch.as_tensor(matx, device=device, dtype=torch.float32)
    # dk.Close()
    # caliperpy.TransCAD.disconnect()
    return "Hello"

if __name__ in ["__main__", "__ax_main__"]:
    print("in name block")

    # py_data = {
    #     'model_file', resnet_data.model_file[record_num],
    #     'parameter_file', resnet_data.parameter_file[record_num],
    #     'se_file', se_file,
    #     'skim_file', sov_skim,
    #     'Skim table': 'CongTime',
    #     'output_folder', opts.util_dir,
    #     'Input Folder', Args.[Input Folder],
    #     'Input Utilities File', out_mtx,
    #     'Input Utilities Matrix', 'Total',
    #     'tag', tag
    #                 }
    # }
    result = context.run(locals())
