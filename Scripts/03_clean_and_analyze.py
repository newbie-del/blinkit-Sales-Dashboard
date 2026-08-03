"""
Step 3/4 - Cleaning + analysis engine
=====================================

Applies the SAME cleaning rules as `SQL/Data Cleaning.sql`, then computes every
aggregate used by the Excel dashboard and the README insights.

Two jobs:
  1. Cross-check the SQL. Both paths must produce identical numbers; if pandas
     and MySQL disagree, one of them has a bug.
  2. Emit `Reports/analysis_output.json` + `Reports/aggregates.xlsx` so the
     dashboard is built from computed values, never hand-typed ones.

Run: python Scripts/03_clean_and_analyze.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
CSV = ROOT / "Dataset" / "BlinkIT Grocery Data.csv"
REPORTS = ROOT / "Reports"
REPORTS.mkdir(exist_ok=True)

CURRENT_YEAR = 2024


# ==========================================================================
# 1. CLEAN  (mirrors SQL/Data Cleaning.sql step for step)
# ==========================================================================
def clean() -> pd.DataFrame:
    raw = pd.read_csv(CSV, dtype=str, keep_default_na=False, na_values=[""])
    n_raw = len(raw)

    df = raw.rename(columns={
        "Item Identifier": "item_identifier",
        "Item Weight": "item_weight",
        "Item Fat Content": "item_fat_content",
        "Item Visibility": "item_visibility",
        "Item Type": "item_type",
        "Outlet Identifier": "outlet_identifier",
        "Outlet Establishment Year": "outlet_establishment_year",
        "Outlet Size": "outlet_size",
        "Outlet Location Type": "outlet_location_type",
        "Outlet Type": "outlet_type",
        "Sales": "sales",
        "Rating": "rating",
        "Order Date": "order_date",
    })

    # STEP 1 - trim every text column
    for c in df.select_dtypes(include="object"):
        df[c] = df[c].str.strip()

    # STEP 2 - category standardisation: 7 spellings -> 2
    fat_map = {"LF": "Low Fat", "LOW FAT": "Low Fat",
               "REG": "Regular", "REGULAR": "Regular"}
    df["item_fat_content"] = df["item_fat_content"].str.upper().map(fat_map)
    assert df["item_fat_content"].notna().all(), "unmapped fat-content value"

    # STEP 3 - cast numerics; blanks become real NaN
    for c in ["item_weight", "item_visibility", "sales", "rating"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df["outlet_establishment_year"] = df["outlet_establishment_year"].astype(int)

    # zero visibility is impossible -> treat as missing
    df["item_visibility"] = df["item_visibility"].replace(0.0, np.nan)

    # STEP 4 - missing outlet size becomes an explicit band
    df["outlet_size"] = df["outlet_size"].fillna("Unknown").replace("", "Unknown")

    # STEP 5 - rating precision + range clamp
    df["rating"] = df["rating"].round(1).clip(1.0, 5.0)

    # STEP 6 - parse dates
    df["order_date"] = pd.to_datetime(df["order_date"], format="%Y-%m-%d")

    # STEP 7 - deduplicate on the full row
    before = len(df)
    df = df.drop_duplicates()
    n_dupes = before - len(df)

    # STEP 8/9 - impute, flagging every filled value
    df["item_weight_imputed"] = df["item_weight"].isna().astype(int)
    df["item_visibility_imputed"] = df["item_visibility"].isna().astype(int)

    by_item = df.groupby("item_identifier")["item_weight"].transform("median")
    by_type = df.groupby("item_type")["item_weight"].transform("median")
    df["item_weight"] = df["item_weight"].fillna(by_item).fillna(by_type).round(3)

    vis_by_type = df.groupby("item_type")["item_visibility"].transform("median")
    df["item_visibility"] = df["item_visibility"].fillna(vis_by_type).round(6)

    # date parts (denormalised, as in the DDL)
    d = df["order_date"]
    df["outlet_age_years"] = CURRENT_YEAR - df["outlet_establishment_year"]
    df["order_year"] = d.dt.year
    df["order_month"] = d.dt.month
    df["order_month_name"] = d.dt.strftime("%b")
    df["order_quarter"] = d.dt.quarter
    df["order_year_month"] = d.dt.strftime("%Y-%m")
    df["order_weekday"] = d.dt.strftime("%a")
    df["is_weekend"] = d.dt.dayofweek.isin([5, 6]).astype(int)

    # ---- validation: every check must pass -------------------------------
    assert df["item_weight"].notna().all(), "null weight survived"
    assert (df["item_visibility"] > 0).all(), "zero visibility survived"
    assert (df["sales"] > 0).all(), "non-positive sales"
    assert df["rating"].between(1, 5).all(), "rating out of range"
    assert df["item_fat_content"].nunique() == 2, "fat content not collapsed"
    assert not df.duplicated(["item_identifier", "outlet_identifier"]).any(), "grain violated"

    print(f"[clean] raw={n_raw:,}  dupes_removed={n_dupes}  clean={len(df):,}")
    print(f"[clean] revenue removed by dedup = "
          f"{pd.to_numeric(raw['Sales']).sum() - df['sales'].sum():,.2f} INR")
    return df


# ==========================================================================
# 2. AGGREGATE
# ==========================================================================
def pct(s: pd.Series) -> pd.Series:
    return (100 * s / s.sum()).round(2)


def analyse(df: pd.DataFrame) -> dict[str, pd.DataFrame]:
    out: dict[str, pd.DataFrame] = {}
    total_rev = df["sales"].sum()

    # ---- KPIs -----------------------------------------------------------
    out["kpis"] = pd.DataFrame([{
        "total_revenue": round(total_rev, 2),
        "total_records": len(df),
        "total_products": df["item_identifier"].nunique(),
        "total_categories": df["item_type"].nunique(),
        "total_outlets": df["outlet_identifier"].nunique(),
        "total_outlet_types": df["outlet_type"].nunique(),
        "total_tiers": df["outlet_location_type"].nunique(),
        "avg_sale": round(df["sales"].mean(), 2),
        "median_sale": round(df["sales"].median(), 2),
        "avg_rating": round(df["rating"].mean(), 2),
        "avg_weight": round(df["item_weight"].mean(), 2),
        "avg_visibility": round(df["item_visibility"].mean(), 4),
        "revenue_per_outlet": round(total_rev / df["outlet_identifier"].nunique(), 2),
        "period_start": df["order_date"].min().strftime("%Y-%m-%d"),
        "period_end": df["order_date"].max().strftime("%Y-%m-%d"),
        "pct_weight_imputed": round(100 * df["item_weight_imputed"].mean(), 2),
        "pct_visibility_imputed": round(100 * df["item_visibility_imputed"].mean(), 2),
    }])

    # ---- category -------------------------------------------------------
    cat = df.groupby("item_type").agg(
        records=("sales", "size"),
        products=("item_identifier", "nunique"),
        revenue=("sales", "sum"),
        avg_sale=("sales", "mean"),
        avg_rating=("rating", "mean"),
        avg_visibility=("item_visibility", "mean"),
        avg_weight=("item_weight", "mean"),
    ).round(4).sort_values("revenue", ascending=False)
    cat["pct_of_revenue"] = pct(cat["revenue"])
    cat["cumulative_pct"] = cat["pct_of_revenue"].cumsum().round(2)
    cat["revenue_per_kg"] = (cat["revenue"] / (cat["avg_weight"] * cat["records"])).round(2)
    out["category"] = cat.reset_index()

    # ---- outlet ---------------------------------------------------------
    outl = df.groupby(["outlet_identifier", "outlet_type", "outlet_size",
                       "outlet_location_type", "outlet_establishment_year",
                       "outlet_age_years"]).agg(
        records=("sales", "size"),
        revenue=("sales", "sum"),
        avg_sale=("sales", "mean"),
        avg_rating=("rating", "mean"),
        categories_stocked=("item_type", "nunique"),
        products_stocked=("item_identifier", "nunique"),
    ).round(4).reset_index().sort_values("revenue", ascending=False)
    outl["pct_of_revenue"] = pct(outl["revenue"])
    out["outlet"] = outl

    # ---- segments -------------------------------------------------------
    for name, col in [("outlet_type", "outlet_type"),
                      ("tier", "outlet_location_type"),
                      ("outlet_size", "outlet_size"),
                      ("fat_content", "item_fat_content")]:
        g = df.groupby(col).agg(
            stores=("outlet_identifier", "nunique"),
            records=("sales", "size"),
            revenue=("sales", "sum"),
            avg_sale=("sales", "mean"),
            avg_rating=("rating", "mean"),
        ).round(4).sort_values("revenue", ascending=False)
        g["pct_of_revenue"] = pct(g["revenue"])
        g["revenue_per_store"] = (g["revenue"] / g["stores"]).round(2)
        out[name] = g.reset_index()

    # ---- time -----------------------------------------------------------
    mon = df.groupby("order_year_month").agg(
        records=("sales", "size"),
        revenue=("sales", "sum"),
        avg_sale=("sales", "mean"),
        avg_rating=("rating", "mean"),
    ).round(4).reset_index()
    mon["prev_month"] = mon["revenue"].shift(1)
    mon["mom_pct"] = (100 * (mon["revenue"] - mon["prev_month"]) / mon["prev_month"]).round(2)
    mon["moving_avg_3m"] = mon["revenue"].rolling(3, min_periods=1).mean().round(2)
    mon["running_total"] = mon["revenue"].cumsum().round(2)
    mon["yoy_pct"] = (100 * (mon["revenue"] - mon["revenue"].shift(12))
                      / mon["revenue"].shift(12)).round(2)
    out["monthly"] = mon

    yr = df.groupby("order_year").agg(
        records=("sales", "size"), revenue=("sales", "sum"),
        avg_sale=("sales", "mean"), avg_rating=("rating", "mean"),
    ).round(4).reset_index()
    yr["yoy_growth_pct"] = (100 * yr["revenue"].pct_change()).round(2)
    yr["basket_growth_pct"] = (100 * yr["avg_sale"].pct_change()).round(2)
    out["yearly"] = yr

    seas = df.groupby(["order_month", "order_month_name"]).agg(
        revenue=("sales", "sum"), avg_sale=("sales", "mean"),
    ).round(4).reset_index()
    seas["pct_of_revenue"] = pct(seas["revenue"])
    seas["seasonality_index"] = (seas["revenue"] / seas["revenue"].mean()).round(3)
    out["seasonality"] = seas

    # ---- products -------------------------------------------------------
    prod = df.groupby(["item_identifier", "item_type"]).agg(
        outlets_stocked=("sales", "size"),
        revenue=("sales", "sum"),
        avg_sale=("sales", "mean"),
        avg_rating=("rating", "mean"),
        avg_visibility=("item_visibility", "mean"),
    ).round(4).reset_index().sort_values("revenue", ascending=False)
    prod["revenue_rank"] = range(1, len(prod) + 1)
    r_bench, g_bench = prod["revenue"].mean(), prod["avg_rating"].mean()
    prod["segment"] = np.select(
        [(prod.revenue >= r_bench) & (prod.avg_rating >= g_bench),
         (prod.revenue >= r_bench) & (prod.avg_rating < g_bench),
         (prod.revenue < r_bench) & (prod.avg_rating >= g_bench)],
        ["Star", "Fix quality", "Promote"], default="Delist candidate")
    out["products"] = prod
    out["top_products"] = prod.head(10).copy()
    out["bottom_products"] = (prod[prod.outlets_stocked >= 3]
                              .nsmallest(10, "revenue").copy())

    seg = prod.groupby("segment").agg(
        products=("item_identifier", "size"),
        revenue=("revenue", "sum"),
        avg_rating=("avg_rating", "mean"),
    ).round(2).reset_index()
    seg["pct_of_revenue"] = pct(seg["revenue"])
    out["segments"] = seg

    # ABC / Pareto on products
    p = prod.copy()
    p["cum_pct"] = 100 * p["revenue"].cumsum() / p["revenue"].sum()
    p["abc"] = np.select([p.cum_pct <= 80, p.cum_pct <= 95],
                         ["A (top 80% of revenue)", "B (next 15%)"],
                         default="C (final 5%)")
    abc = p.groupby("abc").agg(products=("item_identifier", "size"),
                              revenue=("revenue", "sum")).reset_index()
    abc["pct_of_products"] = pct(abc["products"])
    abc["pct_of_revenue"] = pct(abc["revenue"])
    out["abc"] = abc

    # ---- distributions --------------------------------------------------
    bands = pd.cut(df["sales"], [0, 500, 1000, 2000, 3000, 5000, 8000, np.inf],
                   labels=["A. Under 500", "B. 500-1K", "C. 1K-2K", "D. 2K-3K",
                           "E. 3K-5K", "F. 5K-8K", "G. 8K+"])
    sb = df.groupby(bands, observed=True).agg(
        records=("sales", "size"), revenue=("sales", "sum")).reset_index()
    sb["pct_of_records"] = pct(sb["records"])
    sb["pct_of_revenue"] = pct(sb["revenue"])
    out["sales_bands"] = sb

    rb = pd.cut(df["rating"], [0, 2, 3, 3.5, 4, 4.5, 5.01],
                labels=["1.0-1.9 Critical", "2.0-2.9 Poor", "3.0-3.4 Below par",
                        "3.5-3.9 Acceptable", "4.0-4.4 Good", "4.5-5.0 Excellent"],
                right=False)
    rd = df.groupby(rb, observed=True).agg(
        records=("sales", "size"), revenue=("sales", "sum"),
        avg_sale=("sales", "mean")).round(2).reset_index()
    rd["pct_of_records"] = pct(rd["records"])
    out["rating_dist"] = rd

    # visibility quintiles - the merchandising question
    df = df.copy()
    df["vis_quintile"] = pd.qcut(df["item_visibility"], 5, labels=[1, 2, 3, 4, 5])
    vq = df.groupby("vis_quintile", observed=True).agg(
        records=("sales", "size"),
        avg_visibility=("item_visibility", "mean"),
        avg_sale=("sales", "mean"),
        revenue=("sales", "sum"),
        avg_rating=("rating", "mean"),
    ).round(4).reset_index()
    vq["vis_quintile"] = vq["vis_quintile"].astype(str)
    out["visibility_quintiles"] = vq

    # category x outlet-type pivot
    out["cat_by_outlet_type"] = pd.pivot_table(
        df, index="item_type", columns="outlet_type", values="sales",
        aggfunc="sum", fill_value=0).round(0).reset_index()

    # store growth
    oy = df.pivot_table(index=["outlet_identifier", "outlet_type"],
                        columns="order_year", values="sales", aggfunc="sum")
    oy.columns = [f"rev_{c}" for c in oy.columns]
    oy["growth_pct"] = (100 * (oy.iloc[:, 1] - oy.iloc[:, 0]) / oy.iloc[:, 0]).round(2)
    out["outlet_growth"] = oy.round(2).reset_index().sort_values("growth_pct", ascending=False)

    cy = df.pivot_table(index="item_type", columns="order_year",
                        values="sales", aggfunc="sum")
    cy.columns = [f"rev_{c}" for c in cy.columns]
    cy["growth_pct"] = (100 * (cy.iloc[:, 1] - cy.iloc[:, 0]) / cy.iloc[:, 0]).round(2)
    out["category_growth"] = cy.round(2).reset_index().sort_values("growth_pct", ascending=False)

    # weekday vs weekend
    wk = df.groupby(df["is_weekend"].map({0: "Weekday", 1: "Weekend"})).agg(
        records=("sales", "size"), revenue=("sales", "sum"),
        avg_sale=("sales", "mean")).round(2).reset_index()
    wk.columns = ["day_type", "records", "revenue", "avg_sale"]
    out["weekday"] = wk

    return out


# ==========================================================================
# 3. HEADLINE FACTS for the README insights
# ==========================================================================
def facts(df: pd.DataFrame, a: dict[str, pd.DataFrame]) -> dict:
    k = a["kpis"].iloc[0]
    cat, outl, vq = a["category"], a["outlet"], a["visibility_quintiles"]
    ot, tier, size = a["outlet_type"], a["tier"], a["outlet_size"]
    seas, yr, abc = a["seasonality"], a["yearly"], a["abc"]

    top3_cat_share = round(cat["pct_of_revenue"].head(3).sum(), 1)
    vis_uplift = round(100 * (vq.avg_sale.iloc[-1] - vq.avg_sale.iloc[0])
                       / vq.avg_sale.iloc[0], 1)
    grocery = ot[ot.outlet_type == "Grocery Store"].iloc[0]
    best_fmt = ot.sort_values("revenue_per_store", ascending=False).iloc[0]
    a_class = abc[abc.abc.str.startswith("A")].iloc[0]
    peak = seas.sort_values("revenue", ascending=False).iloc[0]
    trough = seas.sort_values("revenue").iloc[0]
    low_rated = a["products"][a["products"].avg_rating < 3.5]

    return {
        "total_revenue": float(k.total_revenue),
        "total_records": int(k.total_records),
        "total_products": int(k.total_products),
        "avg_sale": float(k.avg_sale),
        "median_sale": float(k.median_sale),
        "avg_rating": float(k.avg_rating),
        "outlets": int(k.total_outlets),
        "top_category": cat.iloc[0].item_type,
        "top_category_pct": float(cat.iloc[0].pct_of_revenue),
        "top3_category_share": top3_cat_share,
        "weakest_category": cat.iloc[-1].item_type,
        "weakest_category_pct": float(cat.iloc[-1].pct_of_revenue),
        "premium_category": cat.sort_values("avg_sale", ascending=False).iloc[0].item_type,
        "premium_avg_sale": float(cat.sort_values("avg_sale", ascending=False).iloc[0].avg_sale),
        "top_outlet": outl.iloc[0].outlet_identifier,
        "top_outlet_pct": float(outl.iloc[0].pct_of_revenue),
        "top_outlet_type": outl.iloc[0].outlet_type,
        "worst_outlet": outl.iloc[-1].outlet_identifier,
        "worst_outlet_pct": float(outl.iloc[-1].pct_of_revenue),
        "best_format": best_fmt.outlet_type,
        "best_format_rps": float(best_fmt.revenue_per_store),
        "grocery_rps": float(grocery.revenue_per_store),
        "format_gap_x": round(best_fmt.revenue_per_store / grocery.revenue_per_store, 1),
        "best_tier": tier.sort_values("revenue_per_store", ascending=False).iloc[0].outlet_location_type,
        "best_tier_rps": float(tier.sort_values("revenue_per_store", ascending=False).iloc[0].revenue_per_store),
        "worst_tier": tier.sort_values("revenue_per_store").iloc[0].outlet_location_type,
        "best_size": size.sort_values("revenue_per_store", ascending=False).iloc[0].outlet_size,
        "vis_uplift_pct": vis_uplift,
        "vis_q1_avg": float(vq.avg_sale.iloc[0]),
        "vis_q5_avg": float(vq.avg_sale.iloc[-1]),
        "a_class_products": int(a_class["products"]),
        "a_class_pct_products": float(a_class.pct_of_products),
        "a_class_pct_revenue": float(a_class.pct_of_revenue),
        "peak_month": peak.order_month_name,
        "peak_index": float(peak.seasonality_index),
        "trough_month": trough.order_month_name,
        "trough_index": float(trough.seasonality_index),
        "yoy_growth": float(yr.yoy_growth_pct.iloc[-1]),
        "basket_growth": float(yr.basket_growth_pct.iloc[-1]),
        "low_rated_count": int(len(low_rated)),
        "low_rated_revenue": round(float(low_rated.revenue.sum()), 2),
        "low_rated_pct": round(100 * float(low_rated.revenue.sum()) / float(k.total_revenue), 2),
        "star_products": int(a["segments"].loc[a["segments"].segment == "Star", "products"].iloc[0]),
        "delist_products": int(a["segments"].loc[a["segments"].segment == "Delist candidate", "products"].iloc[0]),
        "weekend_uplift_pct": round(100 * (a["weekday"].set_index("day_type").loc["Weekend", "avg_sale"]
                                    / a["weekday"].set_index("day_type").loc["Weekday", "avg_sale"] - 1), 1),
        "fastest_growing_category": a["category_growth"].iloc[0].item_type,
        "fastest_growth_pct": float(a["category_growth"].iloc[0].growth_pct),
        "pct_weight_imputed": float(k.pct_weight_imputed),
        "pct_visibility_imputed": float(k.pct_visibility_imputed),
        "low_fat_share": float(a["fat_content"].set_index("item_fat_content").loc["Low Fat", "pct_of_revenue"]),
    }


def main() -> None:
    df = clean()
    agg = analyse(df)
    f = facts(df, agg)

    df.to_parquet(REPORTS / "clean_data.parquet", index=False) if False else None
    df.to_csv(REPORTS / "blinkit_clean.csv", index=False)

    with pd.ExcelWriter(REPORTS / "aggregates.xlsx", engine="openpyxl") as xl:
        for name, frame in agg.items():
            frame.to_excel(xl, sheet_name=name[:31], index=False)

    (REPORTS / "analysis_output.json").write_text(
        json.dumps(f, indent=2, default=str), encoding="utf-8")

    print("\n=== HEADLINE FACTS ===")
    for key, val in f.items():
        print(f"  {key:<28} {val}")
    print(f"\n[saved] {REPORTS/'aggregates.xlsx'}")
    print(f"[saved] {REPORTS/'analysis_output.json'}")
    print(f"[saved] {REPORTS/'blinkit_clean.csv'}")


if __name__ == "__main__":
    main()
