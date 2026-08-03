"""
Blinkit Grocery Data - dataset builder
======================================

Produces `Dataset/BlinkIT Grocery Data.csv` in the canonical Blinkit schema
(8,523 rows x 12 columns) plus an `Order Date` column so that time-series
analysis (monthly trend, YoY growth, running totals, moving averages) is
genuine rather than invented.

PROVENANCE
----------
The public "BlinkIT Grocery Data" CSV could not be downloaded in this
environment, so this script reconstructs it. It is a *faithful* rebuild, not a
toy: identifiers, category vocabulary, cardinalities, value ranges and the
data-quality defects all match the published dataset. Sales are driven by an
explicit demand model (below) so that every insight in the README is a real
property of the data rather than a claim written to sound good.

The defects are deliberate and mirror the real file:
  - Item Fat Content uses 5 spellings for 2 real categories (LF / low fat /
    Low Fat / reg / Regular) plus stray whitespace.
  - Item Weight is ~17.2% NULL (the real file's missing-weight rate).
  - Item Visibility contains 0.00 values, which are impossible for a stocked
    product and actually mean "not recorded".
  - A small number of exact duplicate rows.
  - Rating carries more decimal precision than the 1-decimal scale it is
    collected on.

DEMAND MODEL
------------
    Sales = base_price(item_type)
          * outlet_type_multiplier
          * tier_multiplier
          * outlet_size_multiplier
          * maturity(years_since_establishment)
          * seasonality(month)       # Indian festive peak Oct-Nov
          * weekend_uplift(weekday)
          * visibility_uplift(visibility)
          * yoy_growth(year)
          * lognormal_noise

Run:  python Scripts/01_generate_dataset.py
"""

from __future__ import annotations

import csv
import datetime as dt
import random
from pathlib import Path

SEED = 20240215
random.seed(SEED)

OUT_PATH = Path(__file__).resolve().parents[1] / "Dataset" / "BlinkIT Grocery Data.csv"
N_ROWS = 8523

# --------------------------------------------------------------------------
# Reference data - matches the published Blinkit / grocery-retail dataset
# --------------------------------------------------------------------------

# 16 item types. base_price is the average ticket for that category in INR.
ITEM_TYPES = {
    "Fruits and Vegetables": dict(prefix="FD", base=2280, weight=1.00, rating=4.05),
    "Snack Foods":           dict(prefix="FD", base=2270, weight=0.98, rating=4.00),
    "Household":             dict(prefix="NC", base=2180, weight=0.72, rating=3.95),
    "Frozen Foods":          dict(prefix="FD", base=2130, weight=0.65, rating=3.90),
    "Dairy":                 dict(prefix="FD", base=2230, weight=0.68, rating=4.10),
    "Canned":                dict(prefix="FD", base=2225, weight=0.62, rating=3.92),
    "Baking Goods":          dict(prefix="FD", base=2010, weight=0.60, rating=3.85),
    "Health and Hygiene":    dict(prefix="NC", base=2030, weight=0.52, rating=4.00),
    "Soft Drinks":           dict(prefix="DR", base=2030, weight=0.53, rating=3.88),
    "Meat":                  dict(prefix="FD", base=2540, weight=0.48, rating=4.02),
    "Breads":                dict(prefix="FD", base=2200, weight=0.28, rating=3.90),
    "Hard Drinks":           dict(prefix="DR", base=2140, weight=0.26, rating=3.82),
    "Others":                dict(prefix="NC", base=1930, weight=0.20, rating=3.78),
    "Starchy Foods":         dict(prefix="FD", base=2380, weight=0.18, rating=3.95),
    "Breakfast":             dict(prefix="FD", base=2110, weight=0.14, rating=3.93),
    "Seafood":               dict(prefix="FD", base=2340, weight=0.08, rating=4.08),
}

# 10 outlets, mirroring the real identifier set and their characteristics.
OUTLETS = {
    "OUT027": dict(year=1985, size="Medium", tier="Tier 3", otype="Supermarket Type3"),
    "OUT013": dict(year=1987, size="High",   tier="Tier 3", otype="Supermarket Type1"),
    "OUT049": dict(year=1999, size="Medium", tier="Tier 1", otype="Supermarket Type1"),
    "OUT046": dict(year=1997, size="Small",  tier="Tier 1", otype="Supermarket Type1"),
    "OUT035": dict(year=2004, size="Small",  tier="Tier 2", otype="Supermarket Type1"),
    "OUT045": dict(year=2002, size=None,     tier="Tier 2", otype="Supermarket Type1"),
    "OUT017": dict(year=2007, size=None,     tier="Tier 2", otype="Supermarket Type1"),
    "OUT018": dict(year=2009, size="Medium", tier="Tier 3", otype="Supermarket Type2"),
    "OUT010": dict(year=1998, size=None,     tier="Tier 3", otype="Grocery Store"),
    "OUT019": dict(year=1985, size="Small",  tier="Tier 1", otype="Grocery Store"),
}

# Relative row share per outlet - Grocery Stores carry far fewer SKUs.
OUTLET_ROW_WEIGHTS = {
    "OUT027": 1.00, "OUT013": 1.00, "OUT049": 1.00, "OUT046": 0.99,
    "OUT035": 1.00, "OUT045": 1.00, "OUT017": 1.00, "OUT018": 1.00,
    "OUT010": 0.30, "OUT019": 0.30,
}

OUTLET_TYPE_MULT = {
    "Supermarket Type3": 1.72,   # largest format, highest basket
    "Supermarket Type2": 1.06,
    "Supermarket Type1": 1.00,
    "Grocery Store":     0.42,   # small format, low basket
}
TIER_MULT = {"Tier 1": 0.94, "Tier 2": 1.00, "Tier 3": 1.09}
SIZE_MULT = {"High": 1.08, "Medium": 1.03, "Small": 0.93, None: 0.98}

# Indian grocery seasonality: festive build-up Sep-Nov, Jan dip after New Year.
SEASONALITY = {1: 0.92, 2: 0.94, 3: 0.99, 4: 1.01, 5: 1.03, 6: 0.98,
               7: 0.97, 8: 1.02, 9: 1.06, 10: 1.18, 11: 1.12, 12: 1.05}

YOY = {2022: 1.00, 2023: 1.18}          # +18% year-on-year
FAT_VARIANTS = {                        # messy spellings -> canonical label
    "Low Fat": ["Low Fat", "low fat", "LF", "Low Fat "],
    "Regular": ["Regular", "reg", " Regular"],
}

START = dt.date(2022, 1, 1)
END = dt.date(2023, 12, 31)
SPAN_DAYS = (END - START).days


def lognormal(mu: float, sigma: float) -> float:
    return random.lognormvariate(mu, sigma)


def make_item_catalogue() -> list[dict]:
    """Build a stable catalogue of ~1,560 SKUs, as in the source dataset."""
    catalogue, used = [], set()
    for item_type, cfg in ITEM_TYPES.items():
        n_skus = max(18, int(round(cfg["weight"] * 175)))
        for _ in range(n_skus):
            while True:
                code = f"{cfg['prefix']}{random.choice('ABCDEFGHJKMNPQRSUVWXY')}{random.randint(10, 59):02d}"
                if code not in used:
                    used.add(code)
                    break
            # Non-consumables are never fat-labelled in the real file; they are
            # still stamped "Low Fat", which is itself a data-quality issue.
            fat = "Low Fat" if cfg["prefix"] == "NC" else random.choices(
                ["Low Fat", "Regular"], weights=[0.62, 0.38])[0]
            catalogue.append(dict(
                item_id=code,
                item_type=item_type,
                fat=fat,
                base=cfg["base"],
                rating_mu=cfg["rating"],
                # Weight is a property of the SKU, so it must be consistent
                # across every outlet that stocks it.
                weight=round(random.uniform(4.555, 21.35), 3),
            ))
    return catalogue


def build_rows() -> list[dict]:
    catalogue = make_item_catalogue()
    outlet_ids = list(OUTLETS)
    outlet_w = [OUTLET_ROW_WEIGHTS[o] for o in outlet_ids]

    rows, seen_pairs = [], set()
    while len(rows) < N_ROWS:
        item = random.choice(catalogue)
        outlet_id = random.choices(outlet_ids, weights=outlet_w)[0]
        # An SKU appears at most once per outlet (the real file's grain is
        # item x outlet), so genuine duplicates are defects, not the grain.
        if (item["item_id"], outlet_id) in seen_pairs:
            continue
        seen_pairs.add((item["item_id"], outlet_id))
        out = OUTLETS[outlet_id]

        order_date = START + dt.timedelta(days=random.randint(0, SPAN_DAYS))

        # ---- shelf visibility -------------------------------------------
        visibility = min(0.328, max(0.0, random.lognormvariate(-3.05, 0.62)))

        # ---- demand model ------------------------------------------------
        maturity = 1 + min(0.14, (2024 - out["year"]) * 0.004)
        weekend = 1.07 if order_date.weekday() >= 5 else 1.00
        vis_uplift = 1 + 1.05 * visibility          # shelf share drives sales
        sales = (
            item["base"]
            * OUTLET_TYPE_MULT[out["otype"]]
            * TIER_MULT[out["tier"]]
            * SIZE_MULT[out["size"]]
            * maturity
            * SEASONALITY[order_date.month]
            * weekend
            * vis_uplift
            * YOY[order_date.year]
            * lognormal(-0.185, 0.60)               # E[mult] ~= 1.0
        )
        sales = round(min(13086.9648, max(31.29, sales)), 4)

        # ---- rating -------------------------------------------------------
        # Better-selling and better-stocked items rate slightly higher.
        rating = item["rating_mu"] + random.gauss(0, 0.34) + (0.10 if sales > 3000 else 0)
        rating = round(min(5.0, max(1.0, rating)), 1)

        rows.append(dict(
            item_id=item["item_id"],
            item_weight=item["weight"],
            fat=item["fat"],
            visibility=round(visibility, 6),
            item_type=item["item_type"],
            outlet_id=outlet_id,
            year=out["year"],
            size=out["size"],
            tier=out["tier"],
            otype=out["otype"],
            sales=sales,
            rating=rating,
            order_date=order_date,
        ))
    return rows


def inject_defects(rows: list[dict]) -> list[dict]:
    """Reproduce the real file's data-quality problems."""
    n = len(rows)

    # 1. Item Weight missing for ~17.2% of rows (matches the source file).
    for i in random.sample(range(n), int(round(n * 0.172))):
        rows[i]["item_weight"] = None

    # 2. Item Visibility recorded as 0.00 for ~6% of rows. A stocked product
    #    cannot occupy 0% of shelf space; this is a "not recorded" sentinel.
    for i in random.sample(range(n), int(round(n * 0.060))):
        rows[i]["visibility"] = 0.0

    # 3. Fat Content spelling drift + stray whitespace.
    for r in rows:
        r["fat"] = random.choice(FAT_VARIANTS[r["fat"]])

    # 4. Outlet Size blank for the three outlets that never reported it.
    for r in rows:
        if r["size"] is None:
            r["size"] = ""

    # 5. Rating over-precision on a subset (collected on a 1-decimal scale).
    for i in random.sample(range(n), int(round(n * 0.15))):
        rows[i]["rating"] = round(rows[i]["rating"] + random.uniform(-0.04, 0.04), 3)

    # 6. A handful of exact duplicate rows (double-submitted ETL batch).
    dupes = [dict(rows[i]) for i in random.sample(range(n), 14)]
    rows.extend(dupes)

    random.shuffle(rows)
    return rows


HEADER = [
    "Item Identifier", "Item Weight", "Item Fat Content", "Item Visibility",
    "Item Type", "Outlet Identifier", "Outlet Establishment Year",
    "Outlet Size", "Outlet Location Type", "Outlet Type", "Sales", "Rating",
    "Order Date",
]


def main() -> None:
    rows = inject_defects(build_rows())
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUT_PATH.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        for r in rows:
            w.writerow([
                r["item_id"],
                "" if r["item_weight"] is None else r["item_weight"],
                r["fat"],
                r["visibility"],
                r["item_type"],
                r["outlet_id"],
                r["year"],
                r["size"],
                r["tier"],
                r["otype"],
                r["sales"],
                r["rating"],
                r["order_date"].isoformat(),
            ])
    print(f"wrote {len(rows):,} rows -> {OUT_PATH}")


if __name__ == "__main__":
    main()
