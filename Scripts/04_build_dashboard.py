"""
Step 7 - Executive Excel Dashboard
==================================

Builds `Excel Dashboard/Blinkit Dashboard.xlsx` using Excel COM automation, so
the result contains REAL Excel objects, not pictures of them:

  - a PivotCache over the cleaned data
  - 9 PivotTables
  - 9 native charts bound to those pivots
  - 6 working slicers wired to every chart simultaneously
  - 6 KPI cards driven by GETPIVOTDATA/formulas

Why COM instead of openpyxl: openpyxl cannot create PivotTables or slicers.
A dashboard whose "slicers" are static images is the single fastest way to
lose credibility in an interview, so the real objects matter.

Requires: Microsoft Excel + pywin32.
Run: python Scripts/04_build_dashboard.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pandas as pd
import win32com.client as win32
from win32com.client import constants as c

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
CLEAN = ROOT / "Reports" / "blinkit_clean.csv"
OUT = ROOT / "Excel Dashboard" / "Blinkit Dashboard.xlsx"
OUT.parent.mkdir(parents=True, exist_ok=True)

# ---- Blinkit brand palette (Excel COM wants BGR, not RGB) -----------------
def bgr(hex_rgb: str) -> int:
    r, g, b = int(hex_rgb[0:2], 16), int(hex_rgb[2:4], 16), int(hex_rgb[4:6], 16)
    return b * 65536 + g * 256 + r

YELLOW    = bgr("F8CB46")   # Blinkit primary yellow
GREEN     = bgr("0C831F")   # Blinkit green
DARK      = bgr("1C1C1C")
WHITE     = bgr("FFFFFF")
LIGHT_BG  = bgr("F4F6F8")
GREY_TXT  = bgr("5A6672")
CARD_BG   = bgr("FFFFFF")
ACCENT    = bgr("2E7D32")
RED       = bgr("D64545")
BLUE      = bgr("2F6FED")

# The mso* constants live in the Office typelib, not Excel's, so they are not
# available on win32com's Excel constants object. Use the literal value.
MSO_HORIZONTAL = 1


def dispatch_excel(retries: int = 6):
    """Dispatch Excel, tolerating a prior instance still shutting down.

    Excel raises "Call was rejected by callee" if a previous COM client has
    not fully released it yet, so a short retry loop is required for the
    script to be re-runnable.
    """
    for attempt in range(retries):
        try:
            return win32.gencache.EnsureDispatch("Excel.Application")
        except Exception as exc:
            print(f"  [retry {attempt+1}/{retries}] Excel busy: {str(exc)[:60]}")
            time.sleep(4)
    raise RuntimeError("Could not start Excel. Close any open Excel windows "
                       "and re-run.")


def kill_excel(app):
    try:
        app.DisplayAlerts = True
        app.Quit()
    except Exception:
        pass


def main() -> None:
    df = pd.read_csv(CLEAN)

    # Trim to the columns the dashboard actually uses. A pivot cache over 25
    # unused columns just makes the file bigger and the field list confusing.
    cols = ["item_identifier", "item_type", "item_fat_content", "item_weight",
            "item_visibility", "outlet_identifier", "outlet_establishment_year",
            "outlet_size", "outlet_location_type", "outlet_type", "sales",
            "rating", "order_date", "order_year", "order_month",
            "order_month_name", "order_year_month", "order_quarter"]
    df = df[cols].copy()

    headers = ["Item ID", "Category", "Fat Content", "Item Weight",
               "Item Visibility", "Outlet ID", "Est. Year", "Outlet Size",
               "Location Tier", "Outlet Type", "Sales", "Rating", "Order Date",
               "Year", "Month No", "Month", "Year-Month", "Quarter"]

    # Add a rating band for the distribution chart.
    df["rating_band"] = pd.cut(
        df["rating"], [0, 3, 3.5, 4, 4.5, 5.01],
        labels=["Under 3.0", "3.0-3.4", "3.5-3.9", "4.0-4.4", "4.5-5.0"],
        right=False).astype(str)
    headers.append("Rating Band")

    print(f"[data] {len(df):,} rows x {len(df.columns)} cols")

    excel = dispatch_excel()
    excel.Visible = False
    excel.DisplayAlerts = False
    excel.ScreenUpdating = False

    try:
        wb = excel.Workbooks.Add()
        # Remove the default extra sheets
        while wb.Sheets.Count > 1:
            wb.Sheets(wb.Sheets.Count).Delete()

        # ==================================================================
        # DATA SHEET
        # ==================================================================
        ws_data = wb.Sheets(1)
        ws_data.Name = "Data"

        n_rows, n_cols = len(df), len(df.columns)
        ws_data.Range(ws_data.Cells(1, 1), ws_data.Cells(1, n_cols)).Value = [headers]
        # Bulk write - one COM call instead of 8,523. Writing row by row here
        # would take minutes.
        values = df.astype(object).where(pd.notna(df), None).values.tolist()
        ws_data.Range(ws_data.Cells(2, 1),
                      ws_data.Cells(n_rows + 1, n_cols)).Value = values

        hdr = ws_data.Range(ws_data.Cells(1, 1), ws_data.Cells(1, n_cols))
        hdr.Interior.Color = GREEN
        hdr.Font.Color = WHITE
        hdr.Font.Bold = True
        ws_data.Rows(1).RowHeight = 22
        ws_data.Columns.AutoFit()
        ws_data.Range("A2").Select()
        excel.ActiveWindow.FreezePanes = True

        data_range = ws_data.Range(ws_data.Cells(1, 1),
                                   ws_data.Cells(n_rows + 1, n_cols))
        print(f"[excel] data sheet written")

        # ==================================================================
        # PIVOT SHEET + CACHE
        # ==================================================================
        ws_piv = wb.Sheets.Add(After=ws_data)
        ws_piv.Name = "Pivots"

        cache = wb.PivotCaches().Create(
            SourceType=c.xlDatabase,
            SourceData=data_range)

        def make_pivot(name: str, row_field: str, dest_cell: str,
                       value_field: str = "Sales", func=None,
                       sort_desc: bool = True, top_n: int | None = None,
                       bottom: bool = False):
            """Create one pivot table and return it."""
            pt = cache.CreatePivotTable(
                TableDestination=ws_piv.Range(dest_cell),
                TableName=name)
            pf = pt.PivotFields(row_field)
            pf.Orientation = c.xlRowField
            pf.Position = 1

            data_fld = pt.AddDataField(pt.PivotFields(value_field),
                                       f"{name}_val",
                                       func if func else c.xlSum)
            data_fld.NumberFormat = "#,##0"
            fld_name = data_fld.Name          # Excel may adjust the name

            if top_n:
                # PivotFilters is the reliable modern API. AutoShow throws on
                # high-cardinality fields such as Item ID (1,392 values).
                pf.PivotFilters.Add2(
                    c.xlTopCount if not bottom else c.xlBottomCount,
                    data_fld, top_n)
            if sort_desc:
                # A "bottom N" ranking must lead with the WORST performer, so
                # it sorts ascending; everything else sorts descending.
                pf.AutoSort(c.xlAscending if bottom else c.xlDescending,
                            fld_name)
            return pt

        pivots = {}
        pivots["monthly"] = make_pivot("pvMonthly", "Year-Month", "A1",
                                       sort_desc=False)
        pivots["category"] = make_pivot("pvCategory", "Category", "D1")
        pivots["outlet_type"] = make_pivot("pvOutletType", "Outlet Type", "G1")
        pivots["tier"] = make_pivot("pvTier", "Location Tier", "J1")
        pivots["size"] = make_pivot("pvSize", "Outlet Size", "M1")
        pivots["top_prod"] = make_pivot("pvTopProd", "Item ID", "P1", top_n=10)
        pivots["bottom_prod"] = make_pivot("pvBottomProd", "Item ID", "S1",
                                           top_n=10, bottom=True,
                                           sort_desc=True)
        pivots["rating"] = make_pivot("pvRating", "Rating Band", "V1",
                                      value_field="Sales", func=c.xlCount,
                                      sort_desc=False)
        pivots["fat"] = make_pivot("pvFat", "Fat Content", "Y1")
        print(f"[excel] {len(pivots)} pivot tables created")

        # KPI pivot - single grand total per measure
        ws_piv.Range("AB1").Value = "KPI source"
        pt_kpi = cache.CreatePivotTable(
            TableDestination=ws_piv.Range("AB3"), TableName="pvKPI")
        for fld, fn, fmt in [("Sales", c.xlSum, "#,##0"),
                             ("Sales", c.xlAverage, "#,##0"),
                             ("Rating", c.xlAverage, "0.00"),
                             ("Sales", c.xlCount, "#,##0")]:
            d = pt_kpi.AddDataField(pt_kpi.PivotFields(fld),
                                    f"{fn}_{fld}_{fmt}"[:40], fn)
            d.NumberFormat = fmt

        # ==================================================================
        # DASHBOARD SHEET
        # ==================================================================
        ws = wb.Sheets.Add(Before=ws_data)
        ws.Name = "Dashboard"
        ws.Cells.Interior.Color = LIGHT_BG
        ws.Cells.Font.Name = "Segoe UI"
        excel.ActiveWindow.DisplayGridlines = False

        # ---- Header band -------------------------------------------------
        ws.Range("A1:R3").Merge()
        head = ws.Range("A1:R3")
        head.Interior.Color = YELLOW
        head.Value = "   Blinkit  |  Sales Analytics Dashboard"
        head.Font.Size = 26
        head.Font.Bold = True
        head.Font.Color = DARK
        head.HorizontalAlignment = c.xlLeft
        head.VerticalAlignment = c.xlCenter

        ws.Range("A4:R4").Merge()
        sub = ws.Range("A4:R4")
        sub.Interior.Color = GREEN
        sub.Value = ("   Grocery retail performance  |  "
                     f"{df['order_date'].min()[:10]} to {df['order_date'].max()[:10]}"
                     f"  |  {df['outlet_identifier'].nunique()} outlets  |  "
                     f"{len(df):,} sales records")
        sub.Font.Size = 10
        sub.Font.Color = WHITE
        sub.VerticalAlignment = c.xlCenter
        ws.Rows("4").RowHeight = 20

        # ---- KPI cards ---------------------------------------------------
        # Built from merged CELLS holding live formulas, not floating shapes.
        # Shapes cannot contain formulas, so a shape-based card would freeze at
        # whatever value it was created with - it would look right and be wrong
        # the moment anyone refreshed the data.
        d = f"Data!K2:K{n_rows+1}"        # Sales
        r = f"Data!L2:L{n_rows+1}"        # Rating
        i = f"Data!A2:A{n_rows+1}"        # Item ID
        cat_col = f"Data!B2:B{n_rows+1}"  # Category

        kpis = [
            ("TOTAL REVENUE",  f'=TEXT(SUM({d})/1000000,"0.00")&"M"',      GREEN,  "INR, all outlets"),
            ("AVG SALE VALUE", f'=TEXT(AVERAGE({d}),"#,##0")',             DARK,   "Basket value"),
            ("AVG RATING",     f'=TEXT(AVERAGE({r}),"0.00")&" / 5"',       YELLOW, "Customer satisfaction"),
            ("SALES RECORDS",  f'=TEXT(COUNT({d}),"#,##0")',               DARK,   "Product x outlet rows"),
            ("PRODUCTS",       f'=TEXT(SUMPRODUCT(1/COUNTIF({i},{i})),"#,##0")',       DARK, "Distinct SKUs"),
            ("CATEGORIES",     f'=TEXT(SUMPRODUCT(1/COUNTIF({cat_col},{cat_col})),"0")', DARK, "Item types"),
        ]

        # Lay the cards out on a cell grid: each card spans 3 columns x 4 rows
        # (a thin accent strip + two content columns).
        #
        # Widths are chosen so the 18-column content grid totals ~1400pt - wide
        # enough for a 16:9 screen and for 9 charts to stay legible. The strip
        # columns are set first so the geometry measured below is final.
        ws.Rows("6:9").RowHeight = 19
        for col in range(1, 19):
            # cols 1, 4, 7, ... are the narrow accent strips
            ws.Columns(col).ColumnWidth = 0.6 if (col - 1) % 3 == 0 else 15.9

        for idx, (label, formula, colour, hint) in enumerate(kpis):
            c0 = 1 + idx * 3                      # first column of this card
            rng = ws.Range(ws.Cells(6, c0), ws.Cells(9, c0 + 2))
            rng.Interior.Color = CARD_BG
            rng.Borders.Color = bgr("E3E8EE")
            rng.Borders.Weight = c.xlThin

            # Coloured accent strip down the left edge of the card.
            # Width is already set on the column grid above.
            strip = ws.Range(ws.Cells(6, c0), ws.Cells(9, c0))
            strip.Interior.Color = colour

            lbl = ws.Range(ws.Cells(6, c0 + 1), ws.Cells(6, c0 + 2))
            lbl.Merge()
            lbl.Value = label
            lbl.Font.Size = 9
            lbl.Font.Bold = True
            lbl.Font.Color = GREY_TXT
            lbl.VerticalAlignment = c.xlBottom

            val = ws.Range(ws.Cells(7, c0 + 1), ws.Cells(8, c0 + 2))
            val.Merge()
            val.Formula = formula            # live - recalculates on refresh
            val.Font.Size = 19
            val.Font.Bold = True
            val.Font.Color = DARK
            val.VerticalAlignment = c.xlCenter

            sub_lbl = ws.Range(ws.Cells(9, c0 + 1), ws.Cells(9, c0 + 2))
            sub_lbl.Merge()
            sub_lbl.Value = hint
            sub_lbl.Font.Size = 8
            sub_lbl.Font.Color = GREY_TXT
            sub_lbl.VerticalAlignment = c.xlTop

        print("[excel] KPI cards built")

        # ---- Measure the real content grid -------------------------------
        # Chart positions must be derived from Excel's ACTUAL geometry, not
        # guessed in points. Column width in characters converts to points
        # differently per font, so hardcoded coordinates drift out of
        # alignment with the KPI cards. Reading Left/Width back removes the
        # guesswork entirely.
        GRID_LEFT = ws.Range("A6").Left
        last_card_cell = ws.Cells(6, 18)
        GRID_RIGHT = last_card_cell.Left + last_card_cell.Width
        GRID_W = GRID_RIGHT - GRID_LEFT
        GAP = 10.0

        def grid(cols: int, span: int, index: int) -> tuple[float, float]:
            """Left and width for `span` of `cols` equal columns at `index`."""
            unit = (GRID_W - GAP * (cols - 1)) / cols
            left = GRID_LEFT + index * (unit + GAP)
            return left, unit * span + GAP * (span - 1)

        # Section divider between the KPI strip and the charts.
        ws.Rows("10").RowHeight = 8
        ws.Rows("11").RowHeight = 20
        sec = ws.Range(ws.Cells(11, 1), ws.Cells(11, 18))
        sec.Merge()
        sec.Value = "  PERFORMANCE BREAKDOWN"
        sec.Font.Size = 10
        sec.Font.Bold = True
        sec.Font.Color = GREY_TXT
        sec.VerticalAlignment = c.xlCenter
        ws.Rows("12").RowHeight = 6

        row1_top = ws.Range("A13").Top          # below the section label
        ROW_H = 218.0
        row2_top = row1_top + ROW_H + GAP
        row3_top = row2_top + ROW_H + GAP
        slicer_top = row3_top + ROW_H + GAP

        print(f"[excel] content grid: left={GRID_LEFT:.0f} width={GRID_W:.0f}pt")

        # ---- Charts ------------------------------------------------------
        # Each chart is chosen for what the data has to say, not for variety:
        #   line     -> trend over time (continuity)
        #   bar      -> ranking (length is the easiest visual comparison)
        #   column   -> few discrete categories
        #   doughnut -> a 2-part share where the split IS the message
        # Row 1: trend gets 2/3 width (time series needs horizontal room to be
        #        readable), category ranking takes the remaining third.
        r1a_l, r1a_w = grid(3, 2, 0)
        r1b_l, r1b_w = grid(3, 1, 2)
        # Rows 2 and 3: three equal panels each.
        r2 = [grid(3, 1, i) for i in range(3)]

        chart_specs = [
            ("monthly",     "pvMonthly",    c.xlLineMarkers,     "Monthly Revenue Trend",
             (r1a_l, row1_top, r1a_w, ROW_H), GREEN),
            ("category",    "pvCategory",   c.xlBarClustered,    "Revenue by Category",
             (r1b_l, row1_top, r1b_w, ROW_H), GREEN),

            ("outlet_type", "pvOutletType", c.xlColumnClustered, "Revenue by Outlet Type",
             (r2[0][0], row2_top, r2[0][1], ROW_H), YELLOW),
            ("tier",        "pvTier",       c.xlColumnClustered, "Revenue by Location Tier",
             (r2[1][0], row2_top, r2[1][1], ROW_H), GREEN),
            ("size",        "pvSize",       c.xlColumnClustered, "Revenue by Outlet Size",
             (r2[2][0], row2_top, r2[2][1], ROW_H), YELLOW),

            ("top_prod",    "pvTopProd",    c.xlBarClustered,    "Top 10 Products by Revenue",
             (r2[0][0], row3_top, r2[0][1], ROW_H), GREEN),
            ("bottom_prod", "pvBottomProd", c.xlBarClustered,    "Bottom 10 Products by Revenue",
             (r2[1][0], row3_top, r2[1][1], ROW_H), RED),
            ("rating",      "pvRating",     c.xlColumnClustered, "Rating Distribution",
             (r2[2][0], row3_top, r2[2][1], ROW_H), BLUE),
        ]
        # Doughnut sits beside the rating chart on a 4th row half-width.
        r4a_l, r4a_w = grid(3, 1, 0)
        chart_specs.append(
            ("fat", "pvFat", c.xlDoughnut, "Revenue Share by Fat Content",
             (r4a_l, slicer_top, r4a_w, ROW_H), GREEN))

        for key, pt_name, ctype, title, (l, t, w, h), colour in chart_specs:
            src = ws_piv.PivotTables(pt_name).TableRange1
            co = ws.Shapes.AddChart2(-1, ctype, l, t, w, h)
            ch = co.Chart
            ch.SetSourceData(src)
            ch.HasTitle = True
            ch.ChartTitle.Text = title
            ch.ChartTitle.Font.Size = 12
            ch.ChartTitle.Font.Bold = True
            ch.ChartTitle.Font.Color = DARK
            ch.ChartTitle.Font.Name = "Segoe UI"
            ch.HasLegend = (ctype == c.xlDoughnut)
            if ctype == c.xlDoughnut:
                ch.Legend.Position = c.xlLegendPositionBottom
                ch.Legend.Font.Size = 9
                ch.ApplyDataLabels(c.xlDataLabelsShowPercent)
            else:
                try:
                    ch.SeriesCollection(1).Format.Fill.ForeColor.RGB = colour
                    if ctype == c.xlLineMarkers:
                        ch.SeriesCollection(1).Format.Line.ForeColor.RGB = colour
                        ch.SeriesCollection(1).Format.Line.Weight = 2.25
                except Exception:
                    pass
            ch.ChartArea.Format.Fill.ForeColor.RGB = WHITE
            ch.ChartArea.Format.Line.ForeColor.RGB = bgr("E3E8EE")
            ch.ChartArea.Font.Name = "Segoe UI"
            ch.ChartArea.Font.Size = 9

            # Hide the PivotChart field buttons. They are interactive controls,
            # but the dashboard is filtered by slicers, so on-chart buttons add
            # clutter and overlap the plot area.
            try:
                ch.ShowAllFieldButtons = False
            except Exception:
                pass

            # Bar charts plot the first category at the BOTTOM by default, so a
            # descending pivot renders visually ascending. Reversing the axis
            # puts the largest bar on top, which is how a ranking must read.
            if ctype == c.xlBarClustered:
                try:
                    ch.Axes(c.xlCategory).ReversePlotOrder = True
                except Exception:
                    pass

            # Doughnut labels sit outside the ring and overflow a small frame,
            # so show the legend only and keep the ring clean.
            if ctype == c.xlDoughnut:
                try:
                    ch.ApplyDataLabels(c.xlDataLabelsShowNone)
                    ch.SeriesCollection(1).Points(1).Format.Fill.ForeColor.RGB = GREEN
                    ch.SeriesCollection(1).Points(2).Format.Fill.ForeColor.RGB = YELLOW
                except Exception:
                    pass

            co.Name = f"chart_{key}"
        print(f"[excel] {len(chart_specs)} charts created")

        # ---- Slicers -----------------------------------------------------
        # One slicer connected to EVERY pivot, so a single click re-filters the
        # whole dashboard. A slicer wired to one chart is a demo; wired to all
        # nine it is a tool.
        #
        # COM note: Slicers.Add must be called with NAMED arguments and the
        # `Level` parameter omitted entirely. Passing Level="" positionally
        # throws 0x800A03EC on a non-OLAP (table-based) pivot cache.
        # Slicers occupy the right two-thirds beside the doughnut, in a 4-wide
        # strip so all six fit on one screen without scrolling.
        sl_left0, sl_unit = grid(3, 2, 1)[0], (grid(3, 2, 1)[1] - GAP * 2) / 3
        SL_H = (ROW_H - GAP) / 2
        slicer_specs = []
        for n, field in enumerate(["Category", "Outlet Type", "Location Tier",
                                   "Outlet Size", "Year", "Fat Content"]):
            col, row = n % 3, n // 3
            slicer_specs.append((
                field,
                sl_left0 + col * (sl_unit + GAP),
                slicer_top + row * (SL_H + GAP),
                sl_unit,
                SL_H,
            ))
        all_pivot_names = ["pvMonthly", "pvCategory", "pvOutletType", "pvTier",
                           "pvSize", "pvTopProd", "pvBottomProd", "pvRating",
                           "pvFat", "pvKPI"]
        first_pt = ws_piv.PivotTables("pvCategory")
        n_slicers = 0
        for field, l, t, w, h in slicer_specs:
            try:
                sc = wb.SlicerCaches.Add2(first_pt, field)
                # Connect to every other pivot so one click filters everything.
                for name in all_pivot_names:
                    try:
                        sc.PivotTables.AddPivotTable(ws_piv.PivotTables(name))
                    except Exception:
                        pass
                safe = field.replace(" ", "_")
                sl = sc.Slicers.Add(ws, Name=f"Slicer_{safe}", Caption=field,
                                    Top=t, Left=l, Width=w, Height=h)
                sl.NumberOfColumns = 1
                try:
                    sl.Style = "SlicerStyleLight3"
                except Exception:
                    pass
                n_slicers += 1
            except Exception as e:
                print(f"  [warn] slicer '{field}': {str(e)[:110]}")
        print(f"[excel] {n_slicers}/{len(slicer_specs)} slicers created")
        if n_slicers < len(slicer_specs):
            raise RuntimeError(f"only {n_slicers} slicers created - dashboard "
                               "would ship without working filters")

        # ---- Footer ------------------------------------------------------
        footer_top = slicer_top + ROW_H + GAP * 2
        note = ws.Shapes.AddTextbox(MSO_HORIZONTAL,
                                    GRID_LEFT, footer_top, GRID_W, 44)
        note.TextFrame2.TextRange.Text = (
            "Source: BlinkIT Grocery Data (8,523 cleaned records)   |   "
            "Pipeline: CSV -> MySQL staging -> cleaning -> analytics table -> PivotTables   |   "
            "17.2% of Item Weight and 6.0% of Item Visibility values are imputed "
            "(median by item, then by category) and flagged in the source table.")
        tr = note.TextFrame2.TextRange
        tr.Font.Size = 8.5
        tr.Font.Fill.ForeColor.RGB = GREY_TXT
        tr.Font.Name = "Segoe UI"
        note.Line.Visible = False
        note.Fill.Visible = False

        # ---- Print / capture range -----------------------------------------
        # Derive the last row from real geometry so the preview export and any
        # print never clip the dashboard or trail blank space.
        content_bottom = footer_top + 48
        last_row = 13
        while ws.Cells(last_row, 1).Top < content_bottom and last_row < 400:
            last_row += 1
        ws.PageSetup.PrintArea = f"$A$1:$R${last_row}"
        ws.Names.Add("DashboardCapture", f"=Dashboard!$A$1:$R${last_row}")
        print(f"[excel] capture range A1:R{last_row}")

        ws.Range("A1").Select()
        excel.ActiveWindow.Zoom = 80

        # Hide the working sheets - a manager should see the Dashboard only.
        ws_piv.Visible = 2      # xlSheetVeryHidden
        ws_data.Visible = 0     # xlSheetHidden (still refreshable)

        wb.Sheets("Dashboard").Activate()

        if OUT.exists():
            # A previously-opened copy can still hold a lock. Retry briefly
            # rather than losing the whole build to a stale handle.
            for attempt in range(5):
                try:
                    OUT.unlink()
                    break
                except PermissionError:
                    print(f"  [retry {attempt+1}/5] output file locked - "
                          "close it in Excel if open")
                    time.sleep(3)
            else:
                raise RuntimeError(f"Cannot overwrite {OUT} - it is open "
                                   "in another program.")
        wb.SaveAs(str(OUT), FileFormat=51)   # xlOpenXMLWorkbook
        print(f"[saved] {OUT}")
        wb.Close(SaveChanges=False)

    finally:
        excel.ScreenUpdating = True
        kill_excel(excel)


if __name__ == "__main__":
    main()
