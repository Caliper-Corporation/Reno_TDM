#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import gc
import os
import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.nn.utils import spectral_norm
from torch.utils.data import Dataset, DataLoader, random_split
from typing import Dict, List, Tuple, Optional
import logging
import datetime as dt
from dotenv import load_dotenv
import warnings
import yaml

torch.set_num_threads(os.cpu_count())
torch.set_num_interop_threads(2)

load_dotenv()  # reads variables from a .env file and sets them in os.environ
if not load_dotenv():
    load_dotenv(os.path.join(os.getcwd(), r"WGAN\src\.env"))

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

def setup_logger(local_output_folder):
    file_handler = logging.FileHandler(f"{local_output_folder}/{dt.datetime.now().strftime('%Y%m%d_%H%M%S')}_log.txt")
    file_handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter('[%(asctime)s][%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

def setup_seed(seed: int = 42):
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = False
    torch.backends.cudnn.benchmark = False

PERIODS = ["EA", "AM", "MD", "PM", "NT"]
PERIOD_TO_IDX = {p:i for i,p in enumerate(PERIODS)}

def _lower_cols(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy(); df.columns = [c.lower() for c in df.columns]; return df

def load_od_dataframe(path: str) -> pd.DataFrame:
    ext = os.path.splitext(path)[1].lower()
    df = pd.read_parquet(path) if ext in [".parquet",".pq"] else pd.read_csv(path)
    required = {"origin_taz","dest_taz","period","trips"}
    missing = required - set(df.columns)
    if missing: raise ValueError(f"OD file missing columns: {missing}")
    df["period"] = df["period"].astype(str).str.upper().str.strip()
    if not set(df["period"].unique()).issubset(set(PERIODS)):
        bad = set(df["period"].unique()) - set(PERIODS)
        raise ValueError(f"Unknown period(s) in OD data: {bad}. Expected one of {PERIODS}.")
    return df

def load_time_dataframe_periodic(path: str) -> pd.DataFrame:
    ext = os.path.splitext(path)[1].lower()
    df = pd.read_parquet(path) if ext in [".parquet",".pq"] else pd.read_csv(path)
    df = _lower_cols(df)
    is_long = ("period" in df.columns) and (("time" in df.columns) or ("time_min" in df.columns))
    wide_cols = set(["ea_time","am_time","md_time","pm_time","nt_time"])
    has_wide = len(wide_cols.intersection(set(df.columns))) >= 3
    if is_long:
        tcol = "time_min" if "time_min" in df.columns else "time"
        required = {"origin_taz","dest_taz","period", tcol}
        missing = required - set(df.columns)
        if missing: raise ValueError(f"Time (long) file missing columns: {missing}")
        out = df[["origin_taz","dest_taz","period", tcol]].copy().rename(columns={tcol:"time"})
        out["period"] = out["period"].astype(str).str.upper().str.strip()
        if not set(out["period"].unique()).issubset(set(PERIODS)):
            bad = set(out["period"].unique()) - set(PERIODS)
            raise ValueError(f"Unknown period(s) in time matrix: {bad}. Expected one of {PERIODS}.")
        return out
    if has_wide:
        for col in ["ea_time","am_time","md_time","pm_time","nt_time"]:
            if col not in df.columns: df[col] = np.nan
        for c in ["origin_taz","dest_taz"]:
            if c not in df.columns: raise ValueError(f"Time (wide) file missing '{c}' column.")
        long_df = df.melt(id_vars=["origin_taz","dest_taz"],
                          value_vars=["ea_time","am_time","md_time","pm_time","nt_time"],
                          var_name="period_col", value_name="time")
        long_df["period"] = long_df["period_col"].str.replace("_time","",regex=False).str.upper()
        long_df = long_df.drop(columns=["period_col"]).dropna(subset=["time"])
        if not set(long_df["period"].unique()).issubset(set(PERIODS)):
            bad = set(long_df["period"].unique()) - set(PERIODS)
            raise ValueError(f"Unknown period(s) parsed from wide time matrix: {bad}.")
        return long_df[["origin_taz","dest_taz","period","time"]]
    raise ValueError("Time matrix must be either long format (origin_taz, dest_taz, period, time/time_min) "
                     "or wide format (ea_time, am_time, md_time, pm_time, nt_time).")

def load_socio_dataframe(path: str) -> pd.DataFrame:
    ext = os.path.splitext(path)[1].lower()
    df = pd.read_parquet(path) if ext in [".parquet",".pq"] else pd.read_csv(path)
    return df

def load_distance_matrix(path: str, taz_to_idx: Dict) -> pd.DataFrame:
    ext = os.path.splitext(path)[1].lower()
    df = pd.read_parquet(path) if ext in [".parquet",".pq"] else pd.read_csv(path)
    df['orig_idx'] = df['orig_taz'].map(taz_to_idx).astype(np.int16)
    df['dest_idx'] = df['dest_taz'].map(taz_to_idx).astype(np.int16)
    return df

def build_taz_index_map(od_df, time_long_df, socio_df):
    tazs = set(socio_df["taz_idx"].unique())
    tazs = sorted(list(tazs))
    taz_to_idx = {t:i for i,t in enumerate(tazs)}
    return taz_to_idx, np.array(tazs)

def prepare_destination_socio_features(socio_df, taz_to_idx, se_cols: list = None, flat: bool = False):
    socio_df = socio_df.copy()
    socio_df["taz_idx"] = socio_df["taz"].map(taz_to_idx)
    socio_df = socio_df.dropna(subset=["taz_idx"]); socio_df["taz_idx"] = socio_df["taz_idx"].astype(int)
    socio_df = socio_df.sort_values("taz_idx")
    if se_cols is None:
        print("You need to specify SEDATA colums")
        raise ValueError("You need to specify SEDATA colums")
    if not all(i in socio_df.columns for i in se_cols):
        print("SEDATA columns specified that does not exist in the data")
        raise ValueError("SEDATA columns specified that does not exist in the data")
    cols = se_cols
    feats = socio_df[cols].astype(float).values
    ### Logarithmic 0-1 scaling
    feats = (np.log1p(feats) / np.log1p(feats).max())
    n = len(taz_to_idx)
    if not flat:
        out = np.zeros((n, feats.shape[1]), dtype=np.float32)
        out[socio_df["taz_idx"].values] = feats.astype(np.float32)
    else:
        out = np.zeros(n * feats.shape[1])
        out = feats.flatten('F')
    return out

def prepare_origin_socio_features(socio_df, taz_to_idx, se_cols: list = None, flat: bool = False):
    socio_df = socio_df.copy()
    socio_df["taz_idx"] = socio_df["taz"].map(taz_to_idx)
    socio_df = socio_df.dropna(subset=["taz_idx"]); socio_df["taz_idx"] = socio_df["taz_idx"].astype(int)
    socio_df = socio_df.sort_values("taz_idx")
    if se_cols is None:
        print("You need to specify SEDATA colums")
        raise ValueError("You need to specify SEDATA colums")
    if not all(i in socio_df.columns for i in se_cols):
        print("SEDATA columns specified that does not exist in the data")
        raise ValueError("SEDATA columns specified that does not exist in the data")
    cols = se_cols

def build_origin_period_distributions(od_df, taz_to_idx):
    n = len(taz_to_idx); out = {}
    grouped = od_df.groupby(["origin_taz","period"]) 
    for (o_taz, per), g in grouped:
        dests = g["dest_taz"].map(taz_to_idx).values
        trips = g["trips"].astype(float).values
        vec = np.zeros(n, dtype=np.float32)
        np.add.at(vec, dests, trips)
        s = vec.sum()
        vec = (vec / s) if s > 0 else np.full(n, 1.0/n, dtype=np.float32)
        out[(taz_to_idx[o_taz], PERIOD_TO_IDX[per])] = vec
    return out

def get_origin_period_trips(od_df, taz_to_idx):
    n = len(taz_to_idx); out = {}
    grouped = od_df.groupby(["origin_taz","period"]) 
    for (o_taz, per), g in grouped:
        dests = g["dest_taz"].map(taz_to_idx).values
        trips = g["trips"].astype(float).values
        vec = np.zeros(n, dtype=np.float32)
        np.add.at(vec, dests, trips)
        out[(taz_to_idx[o_taz], PERIOD_TO_IDX[per])] = vec
    return out

class ODDataset(Dataset):
    def __init__(self, origin_period_to_dist, n_taz):
        self.keys = list(origin_period_to_dist.keys())
        self.n_records = len(origin_period_to_dist)
        self.origin_period_to_dist = origin_period_to_dist
        self.n_taz = n_taz
    def __len__(self): return self.n_records
    def __getitem__(self, idx):
        o_idx, p_idx = self.keys[idx]
        target = self.origin_period_to_dist[(o_idx, p_idx)]
        return {"origin_idx": np.int64(o_idx),
                "period_idx": np.int64(p_idx),
                "target": target.astype(np.float32)}

class SinkhornDistance(nn.Module):
    """
    Differentiable Sinkhorn distance between two discrete distributions p, q over N points,
    using a given cost matrix C (N x N). Computes an approximation to W2^2 with entropic reg.

    References:
    - Cuturi (2013) Sinkhorn Distances: Lightspeed Computation of Optimal Transport
    - Log-stabilized implementation (vectorized) for batches
    """
    def __init__(self, cost: torch.Tensor, epsilon: float = 0.1, max_iters: int = 200, tol: float = 1e-6):
        super().__init__()
        # cost: (N, N)
        self.register_buffer("C", cost)  # normalized [0,1]
        self.epsilon = epsilon
        self.max_iters = max_iters
        self.tol = tol
        print(f"Sinkhorn stats: ε = {self.epsilon}, tol = {self.tol}, max iterations: {self.max_iters}")

    def forward(self, p: torch.Tensor, q: torch.Tensor) -> torch.Tensor:
        """
        p, q: (B, N) valid probability distributions (sum=1)
        returns: scalar mean Sinkhorn distance over batch
        """
        K = torch.exp(-self.C / self.epsilon)  # (N, N)
        Kp = K  # alias

        # Initialize u, v
        B, N = p.shape
        u = torch.ones(B, N, device=p.device) / N
        v = torch.ones(B, N, device=p.device) / N

        # Use log-domain stabilization
        # But here K is normalized; still iterate standard Sinkhorn
        for s_i in range(self.max_iters):
            u_prev = u
            # Avoid division by zero
            Kv = torch.matmul(v, Kp.T) + 1e-12  # (B, N)
            u = p / Kv
            Ku = torch.matmul(u, Kp) + 1e-12    # (B, N)
            v = q / Ku

            # Convergence check on u
            if self.tol > 0:
                err = (u - u_prev).abs().mean()
                if err.item() < self.tol:
                    break
        if s_i == self.max_iters:
            logger.warning(f"Sinkhorn did not converge")
        # Transport plan: diag(u) K diag(v)
        # Expected cost: sum_ij T_ij * C_ij
        T = torch.matmul(torch.matmul(torch.diag_embed(u), Kp), torch.diag_embed(v))  # (B, N, N)
        cost = (T * self.C).sum(dim=(1,2))  # (B,)
        return cost.mean()

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

class BigGenerator(nn.Module):
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

class ConditionalDistanceDiscriminator(nn.Module):
    """
    Discriminator for conditional GAN:
      - condition: dist  [batch, num_outcomes]
      - sample:    x     [batch, num_outcomes]  (real or generated distribution)
    Output:
      - logits     [batch, 1]
    """

    def __init__(
        self,
        input_dim: int,
        num_outcomes: int,
        hidden_dims=(128, 128),
        dropout: float = 0.1,
    ):
        super().__init__()
        self.num_outcomes = num_outcomes
        layers = []
        prev = input_dim
        for h in hidden_dims:
            layers += [
                nn.Linear(prev, h),
                nn.LeakyReLU(0.2, inplace=True),
                nn.Dropout(dropout),
            ]
            prev = h

        self.mlp = nn.Sequential(*layers)
        self.out = nn.Linear(prev, 1)  # logits

    def forward(self, dist: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
        """
        dist: [batch, num_outcomes]
        x:    [batch, num_outcomes]
        returns logits: [batch, 1]
        """
        inp = torch.cat([dist, x], dim=1)  
        h = self.mlp(inp)
        logits = self.out(h)
        return logits

def bce_with_logits_loss(logits, targets): return F.binary_cross_entropy_with_logits(logits, targets)

def to_tensor(x, device, dtype=torch.float32):
    if isinstance(x, torch.Tensor): return x.to(device=device, dtype=dtype)
    return torch.as_tensor(x, device=device, dtype=dtype)

def compute_period_wd_loss(fake, target, distance_matrix):
    diff = (fake - target) #.abs()
    return (diff * (distance_matrix ** 2.0)).sum()

def dist_cross_entropy(pred_probs, target_probs, reduction="sum"):
    # pred_probs, target_probs: [batch, C], both sum to 1 along dim=1
    eps = 1e-12
    ce = -(target_probs * torch.log(pred_probs + eps)).sum(dim=1)  # [batch]
    if reduction == "sum":
        return ce.sum()
    elif reduction == "mean":
        return ce.mean()
    else:
        return ce

def train_loop(args):
    device = torch.device("cuda" if torch.cuda.is_available() and not args['cpu'] else "cpu")
    print(f"Using device: {device}")
    od_df = load_od_dataframe(args['od_path'])
    
    time_long_df = load_time_dataframe_periodic(args['time_path'])
    socio_df = load_socio_dataframe(args['socio_path'])
    taz_to_idx, taz_ids = build_taz_index_map(od_df, time_long_df, socio_df)
    n_taz = socio_df.shape[0] #len(taz_to_idx)
    print(f"Found {n_taz} unique TAZ.")

    if not args['ose_cols'] is None: #prepare_origin_socio_features
        orig_feats = prepare_destination_socio_features(socio_df, taz_to_idx, args['ose_cols'], False)
        orig_feats_torch = torch.as_tensor(orig_feats, device=device, dtype=torch.float32)
        del(orig_feats)

    if not args['dse_cols'] is None:
        dest_feats = prepare_destination_socio_features(socio_df, taz_to_idx, args['dse_cols'], False)
        dest_feats_torch = torch.as_tensor(dest_feats.flatten('F'), device=device, dtype=torch.float32) 
        del(dest_feats)

    matx = np.zeros((len(PERIODS), time_long_df['origin_taz'].nunique(), time_long_df['dest_taz'].nunique()), dtype=np.float32)
    matx[time_long_df['period'].map(PERIOD_TO_IDX), time_long_df['origin_taz'] - 1, time_long_df["dest_taz"] - 1] = time_long_df['time']
    matx[:] = np.log1p(matx) / np.log1p(matx).max()
    matx_torch = torch.as_tensor(matx, device=device, dtype=torch.float32)  # [P, n_orig, n_dest]
    del(matx)

    dmatx = np.zeros((time_long_df['origin_taz'].nunique(), time_long_df['dest_taz'].nunique()), dtype=np.float32)
    if not args['dist_path'] is None:    
        dist_mat = load_distance_matrix(args['dist_path'], taz_to_idx)
        dmatx[dist_mat['orig_idx'], dist_mat["dest_idx"]] = dist_mat['dist']
    dmatx_torch = torch.as_tensor(dmatx, device = device, dtype = torch.float32)

    C_t = (dmatx_torch ** 2.0)
    sinkhorn = SinkhornDistance(cost=C_t, epsilon=args['sinkhorn_epsilon'], max_iters=args['sinkhorn_iters'], tol=args['sinkhorn_tol']).to(device)

    # Build an intrardistrict matrix
    if args['build_intradistrict_matrix_field'] != 'None':
        if not args['build_intradistrict_matrix_field'] in socio_df.columns:
            raise RuntimeError(f"Field {args['build_intradistrict_matrix_field']} not in sedata!")
        interdist_mtx = torch.zeros_like(matx_torch[0])
        for d in socio_df[args['build_intradistrict_matrix_field']]:
            taz_idxs = socio_df[socio_df[args['build_intradistrict_matrix_field']] == d]['taz_idx'].map(taz_to_idx) #FIXME: hardcoded!
            for i in taz_idxs:
                for j in taz_idxs:
                    interdist_mtx[int(i), int(j)] = 1
    
    # Build an intrazonal matrix
    if args['use_intrazonal']:
        intrazonal_mtx = torch.zeros_like(matx_torch[0], dtype=torch.int)
        intrazonal_mtx.fill_diagonal_(1)

    cond_dim = len(PERIODS)
    od_df['period_idx'] = od_df['period'].map(PERIOD_TO_IDX)
    origin_period_to_dist = build_origin_period_distributions(od_df, taz_to_idx)
    train_dataset_trips = get_origin_period_trips(od_df, taz_to_idx)
    
    test_od = load_od_dataframe(args['test_od_path'])
    test_period_to_dist = build_origin_period_distributions(test_od, taz_to_idx)
    test_dataset = ODDataset(test_period_to_dist, n_taz)
    test_dataset_trips = get_origin_period_trips(test_od, taz_to_idx)

    dataset = ODDataset(origin_period_to_dist, n_taz)
    
    n_train = len(dataset) #int(len(dataset) * (1.0 - args['val_split']))
    n_val = len(test_dataset) #- n_train
    train_loader = DataLoader(dataset, batch_size=args['batch_size'], shuffle=True, drop_last=True)
    val_loader = DataLoader(test_dataset, batch_size=args['batch_size'], shuffle=True, drop_last=False)
    
    if args['use_wandb'] != 0:
        wandb.init(project=args['wandb_project_name'], config=args)
        wandb.config.update({"n_taz": n_taz, "cond_dim": cond_dim})

    taz_mult = 1.0
    if args['build_intradistrict_matrix_field'] != 'None':
        taz_mult += 1.0
    if args['use_intrazonal']:
        taz_mult += 1.0

    input_dims_len = int(taz_mult * dataset.n_taz)
    if not args['dse_cols'] is None:
        input_dims_len += dest_feats_torch.shape[0] #* dest_feats_torch.shape[1]

    if not args['ose_cols'] is None:
        input_dims_len += orig_feats_torch.shape[1]


    G = BigGenerator(input_dim=input_dims_len, output_dim=dataset.n_taz, hidden_dim = args['hidden'], depth = args['depth'], dropout=args['dropout']).to(device) 
    D = ConditionalDistanceDiscriminator(input_dim=input_dims_len + dataset.n_taz, num_outcomes=dataset.n_taz).to(device) 
    update_setup_file(args = args, input_dim = input_dims_len, output_dim = dataset.n_taz)
    optG = torch.optim.AdamW(G.parameters(), lr = args['glr'], betas = (0.8, 0.9), weight_decay = 1e-2)
    optD = torch.optim.Adam(D.parameters(), lr=args['dlr'], betas=(0.5, 0.999))

    best_val_w2 = float("inf")
    best_val_cel = float("inf")
    best_val_g_loss = float("inf")
    
    test_ll = 0.0
    patience = 8
    bad = 0
    gc.collect()   
    print(f"Using {n_train:,.0f} origins for training, using {n_val:,.0f} origins for validation")
    logger.info(f"Using {n_train:,.0f} origins for training, using {n_val:,.0f} samples for validation")
    for epoch in range(1, args['epochs'] + 1):
        logger.info(f"Start epoch {epoch}")
        null_loss = 0
        ce_loss = 0
        ce_loss_sum = 0
        G.train()
        D.train()
        g_loss_epoch = 0.0
        d_loss_epoch = 0.0
        train_ll = 0.0
        test_ll = 0.0
        d_loss_real = 0.0
        d_loss_fake = 0.0
        w2_loss_epoch = 0
        cel_loss_epoch = 0
        tot_cel = 0.0
        tot_w2 = 0.0
        if epoch <= 10:
            eps, iters = 0.12, 100
        elif epoch <= 20:
            eps, iters = 0.10, 120
        else:
            eps, iters = 0.08, 150
        val_w2 = 0
        batch_number = 1
        for batch_idx, batch in enumerate(train_loader):
            batch_number += 1
            batch_size = batch['origin_idx'].shape[0]
            target = batch["target"].to(device, non_blocking=True, dtype=torch.float32)
            target_matrix = torch.zeros(size=(batch_size, n_taz))
            target_matrix = target_matrix / target_matrix.sum(dim = 1, keepdim=True).clamp(min=1e-8)
            period_idx = batch["period_idx"].to(device, non_blocking=True, dtype=torch.int64)
            origin_idx = batch['origin_idx'].to(device, non_blocking=True, dtype=torch.int64)
            cost_mtx = matx_torch[period_idx, origin_idx, :]

            if not args['ose_cols'] is None and not args['dse_cols'] is None:
                orig_data = orig_feats_torch[origin_idx]
                emp_data = dest_feats_torch.unsqueeze(0).expand(batch_size, -1)
                emp_data = torch.cat([orig_data, emp_data], dim = 1)
            elif not args['ose_cols'] is None:
                ctx_data = torch.as_tensor(F.one_hot(period_idx, num_classes = len(PERIODS)), device = device, dtype = torch.float32)
                if not args['ose_cols'] is None:
                    orig_atts = torch.as_tensor(socio_df.loc[batch['origin_idx'].numpy(), args['ose_cols']].to_numpy(), device = device, dtype = torch.float32)
                    ctx_data = torch.cat((ctx_data, orig_atts), dim = 1)
            elif not args['dse_cols'] is None:
                emp_data = dest_feats_torch.unsqueeze(0).expand(batch_size, -1)

            optD.zero_grad()
            with torch.no_grad():
                dv = torch.cat([cost_mtx, emp_data], dim = 1)
                if args['build_intradistrict_matrix_field'] != 'None':
                    idmtx = interdist_mtx[origin_idx, :]
                    dv = torch.cat([dv, idmtx], dim = 1)
                if args['use_intrazonal']:
                    izmtx = intrazonal_mtx[origin_idx, :]
                    dv = torch.cat([dv, izmtx], dim = 1)
                fake_dist = G(dv)
                fake_probs = F.softmax(fake_dist, dim = 1)
            real_logits = D(dv, target)
            fake_logits = D(dv, fake_dist)
            d_loss = (F.binary_cross_entropy_with_logits(real_logits, torch.full_like(real_logits, 0.9)) +
                         F.binary_cross_entropy_with_logits(fake_logits, torch.full_like(fake_logits, 0.1)))
            d_loss.backward()
            optD.step()            
            d_loss_epoch += d_loss.item()
            
            optG.zero_grad()
            fake_logits = G(dv)
            fake_probs = F.softmax(fake_logits, dim=1)
                
            # Adversarial loss
            adv_logits = D(dv, fake_probs)
            adv_loss = F.binary_cross_entropy_with_logits(adv_logits, torch.ones_like(adv_logits))

            # Cross-entropy loss
            ce_loss = dist_cross_entropy(fake_probs, target) / batch_size
            tot_cel += dist_cross_entropy(fake_probs, target).detach()

            # Wasserstein loss
            t_w2_loss = sinkhorn(target, fake_probs)
            w2_loss =  t_w2_loss / batch_size
            tot_w2 += t_w2_loss.detach()

            # Combined loss
            adv_mult = 0.1 
            g_loss = args['lambda_cel'] * ce_loss + args['lambda_w2'] * w2_loss + adv_mult * adv_loss
            g_loss.backward()
            total_norm = torch.nn.utils.clip_grad_norm_(G.parameters(), max_norm=5.0)
            optG.step()
            
            g_loss_epoch += g_loss.item()
            w2_loss_epoch += w2_loss.item()
            cel_loss_epoch += ce_loss.item()
            x = [(z, p) for z, p in zip(batch['origin_idx'].detach().numpy(), batch['period_idx'].detach().numpy())]
            epoch_batch_trips = np.zeros([batch_size, n_taz])
            for idx in range(batch_size):
                epoch_batch_trips[idx] = train_dataset_trips[x[idx]]
            train_ll += np.sum(np.nan_to_num(np.log(fake_probs.detach().numpy())) * epoch_batch_trips)
        
        # Epoch statistics
        g_loss_epoch /= max(1, len(train_loader))
        d_loss_epoch /= max(1, len(train_loader))
        cel_loss_epoch /= max(1, len(train_loader))
        w2_loss_epoch /= max(1, len(train_loader))

        # Validation
        G.eval()
        fake_hold = []
        with torch.no_grad():
            val_w2 = 0.0
            n_val_ex = 0
            val_cel = 0.0
            val_cel_tot = 0.0
            val_w2_tot = 0.0
            for batch in val_loader:
                period_idx = batch["period_idx"].to(device, non_blocking=True, dtype=torch.int64)
                origin_idx = batch['origin_idx'].to(device, non_blocking=True, dtype=torch.int64)
                batch_size = batch['origin_idx'].shape[0]
                cost_mtx = matx_torch[period_idx, origin_idx, :]
                target = batch["target"].to(device, non_blocking=True, dtype=torch.float32)

                if not args['ose_cols'] is None and not args['dse_cols'] is None:
                    orig_data = orig_feats_torch[origin_idx]
                    emp_data = dest_feats_torch.unsqueeze(0).expand(batch_size, -1)
                    emp_data = torch.cat([orig_data, emp_data], dim = 1)
                elif not args['ose_cols'] is None:
                    ctx_data = torch.as_tensor(F.one_hot(period_idx, num_classes = len(PERIODS)), device = device, dtype = torch.float32)
                    if not args['ose_cols'] is None:
                        orig_atts = torch.as_tensor(socio_df.loc[batch['origin_idx'].numpy(), args['ose_cols']].to_numpy(), device = device, dtype = torch.float32)
                        ctx_data = torch.cat((ctx_data, orig_atts), dim = 1)
                elif not args['dse_cols'] is None:
                    emp_data = dest_feats_torch.unsqueeze(0).expand(batch_size, -1)

                dv = torch.cat([cost_mtx, emp_data], dim = 1)
                if args['build_intradistrict_matrix_field'] != 'None':
                    idmtx = interdist_mtx[origin_idx, :]
                    dv = torch.cat([dv, idmtx], dim = 1)
                    # emp_data = torch.cat([emp_data, izmtx], dim = 1)
                if args['use_intrazonal']:
                    izmtx = intrazonal_mtx[origin_idx, :]
                    dv = torch.cat([dv, izmtx], dim = 1)
                fake = G(dv)

                fake_probs = F.softmax(fake, dim=1)
                fake_hold += fake_probs
                dist_mtx = dmatx_torch[:, origin_idx].T

                # Cross-entropy loss
                cel_loss = dist_cross_entropy(fake_probs, target).detach() / batch_size
                val_cel_tot += dist_cross_entropy(fake_probs, target).detach()

                # Wasserstein loss
                t_w2_loss = sinkhorn(target, fake_probs).detach()
                w2_loss =  t_w2_loss / batch_size
                val_w2_tot += t_w2_loss

                val_w2 += w2_loss
                val_cel += cel_loss

                x = [(z, p) for z, p in zip(batch['origin_idx'].detach().numpy(), batch['period_idx'].detach().numpy())]
                epoch_batch_trips = np.zeros([batch_size, n_taz])
                for idx in range(batch_size):
                    epoch_batch_trips[idx] = test_dataset_trips[x[idx]]
                test_ll += np.sum(np.nan_to_num(np.log(fake_probs.detach().numpy())) * epoch_batch_trips)

                n_val_ex += batch_size
            val_w2 /= len(val_loader)
            val_cel /= len(val_loader)

        if args['use_wandb'] != 0:
            log_dict = {
                "train/D_loss": d_loss_epoch,
                "train/G_loss": g_loss_epoch,
                "train/G_adv_loss": adv_loss.item(),
                "train/cel": cel_loss_epoch,
                "train/W2": w2_loss_epoch,
                "train/total_norm": total_norm,
                "train/loglike": train_ll,
                "epoch": epoch,
                "val/W2": val_w2,
                "val/cel": val_cel,
                "val/loglike": test_ll,
            }
            wandb.log(log_dict)

        print(f"Epoch {epoch:03d}/{args['epochs']} | D_loss: {d_loss_epoch:.4f} | G_loss: {g_loss_epoch:.4f} | Train_W2: {w2_loss_epoch:,.2f} | Val_W2: {val_w2_tot:,.2f} | Train_CEL: {tot_cel:,.2f} | Val_CEL: {val_cel_tot:,.2f} | Grad Norm: {total_norm:,.2f} | train LL: {train_ll:,.0f} | test LL: {test_ll:,.2f}")
        logger.info(f"Epoch {epoch:03d}/{args['epochs']} | D_loss: {d_loss_epoch:.4f} | G_loss: {g_loss_epoch:.4f} | Train_W2: {w2_loss_epoch:,.2f} | Val_W2: {val_w2_tot:,.2f} | Train_CEL: {tot_cel:,.2f} | Val_CEL: {val_cel_tot:,.2f} | Grad Norm: {total_norm:,.2f} | train LL: {train_ll:,.0f} | test LL: {test_ll:,.2f}")

        if epoch < 75:
            bad = 0
        if g_loss_epoch < best_val_g_loss:
            torch.save({"G_state_dict": G.state_dict(),
                        "taz_ids": taz_ids,
                        "cond_dim": cond_dim,
                        "n_taz": n_taz,
                        "dest_features": dest_feats_torch,
                        "matrix": matx_torch,
                        "args": args}, os.path.join(args['save_dir'], "best_model.pt"))
            print(f"  ✓ Saved best model (G Loss={g_loss_epoch:.6f}) to {args['save_dir']}/best_model.pt")
            logger.info(f"Saved best model (G Loss={g_loss_epoch:.6f}) to {args['save_dir']}/best_model.pt")
            best_val_g_loss = g_loss_epoch    
            bad = 0 # resetting this to ensure that the lack of improvement is in a row
        else:
            bad += 1
            if bad >= patience:
                print(f"Early stop at epoch {epoch} (best Val_W2={best_val_w2:.6f})")
                break
        if cel_loss_epoch < best_val_cel:
            torch.save({"G_state_dict": G.state_dict(),
                        # "D_state_dict": D.state_dict(),
                        "taz_ids": taz_ids,
                        "cond_dim": cond_dim,
                        "n_taz": n_taz,
                        "dest_features": dest_feats_torch,
                        "matrix": matx_torch,
                        "args": args}, os.path.join(args['save_dir'], "best_model_cel.pt"))
            print(f"  ✓ Saved best model (CEL) (CEL={cel_loss_epoch:,.2f}) to {args['save_dir']}/best_model_cel.pt")
            logger.info(f"Saved best model  (CEL) (CEL={cel_loss_epoch:,.2f}) to {args['save_dir']}/best_model_cel.pt")
            best_val_cel = cel_loss_epoch  
            bad = 0 # resetting this to ensure that the lack of improvement is in a row
        if w2_loss_epoch < best_val_w2:
            torch.save({"G_state_dict": G.state_dict(),
                        # "D_state_dict": D.state_dict(),
                        "taz_ids": taz_ids,
                        "cond_dim": cond_dim,
                        "n_taz": n_taz,
                        "dest_features": dest_feats_torch,
                        "matrix": matx_torch,
                        "args": args}, os.path.join(args['save_dir'], "best_model_cel.pt"))
            print(f"  ✓ Saved best model (W2) (W2={w2_loss_epoch:,.2f}) to {args['save_dir']}/best_model_w2.pt")
            logger.info(f"Saved best model  (W2) (W2={w2_loss_epoch:,.2f}) to {args['save_dir']}/best_model_w2.pt")
            best_val_w2 = w2_loss_epoch
            bad = 0

            
    torch.save(G.state_dict(), os.path.join(args['save_dir'], "G_final.pt"))
    torch.save(D.state_dict(), os.path.join(args['save_dir'], "D_final.pt"))
    
    print("Training complete. Models saved.")
    logger.info("Training complete. Models saved.")

def update_setup_file(args, input_dim, output_dim):
    config = yaml.load(open(os.path.join(args['save_dir'], 'model_setup.yaml')), Loader = yaml.SafeLoader)
    config['input_dim'] = input_dim
    config['output_dim'] = output_dim
    with open(os.path.join(args['save_dir'], 'model_setup.yaml'), 'w') as file:
        yaml.dump(config, file, sort_keys=False)
    

def parse_setup_file(f):
    config = yaml.load(open(f), Loader = yaml.SafeLoader)
    default_items = {
        'ose_cols': None,
        'dse_cols': None,
        'epochs': 20,
        'batch_size': 64,
        'glr': 1e-3,
        'dlr': 1e-3,
        # 'noise_dim': 64,
        'hidden': 512,
        # 'dest_embed_dim': 256,
        'val_split': 0.15,
        'lambda_w2': 0.1,
        'lambda_cel': 0.1,
        'save_dir': './outputs',
        'test_od_path': None,
        # 'test_time_path': None,
        # 'test_socio_path': None,
        # 'saved_model_path': None,
        'dist_path': None,
        # 'speed_kmph': None,
        # 'lambda_dist': 0.5,
        # 'gravity_gamma': 1.0,
        # 'lambda_gamma_l2': 0.0,
        'use_wandb': 0,
        # 'max_recs': 0,
        'sinkhorn_epsilon': 0.1,
        'sinkhorn_iters': 200,
        'sinkhorn_tol': 1e-6,
        'grad_accum_steps': 1,
        'depth': 3,
        'dropout': 0.1,
        'build_intradistrict_matrix_field': 'None',
        'use_intrazonal': False,
    }
    for k in default_items.keys():
        if not k in config:
            config[k] = default_items[k]

    return config

def main(args):
    # Setup save dir, logger, and dump current config into save dir for testing
    os.makedirs(args['save_dir'], exist_ok=True)
    setup_logger(os.path.join(args['save_dir']))
    with open(os.path.join(args['save_dir'], 'model_setup.yaml'), 'w') as file:
        yaml.dump(args, file, sort_keys=False)
    setup_seed(42)
    train_loop(args)

if __name__ == "__main__":        
    print("intra-op threads:", torch.get_num_threads())
    print("interop threads:", torch.get_num_interop_threads())
    ap = argparse.ArgumentParser(description="OD GAN (Quadratic W2) — Destination-conditioned")
    ap.add_argument("--setup_file", type=str, required=True)
    args_in = ap.parse_args()
    args = parse_setup_file(args_in.setup_file)
    if args['use_wandb'] != 0:
        import wandb
        print("Using wandb...")
    main(args)
