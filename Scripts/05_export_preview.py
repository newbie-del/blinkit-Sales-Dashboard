"""
Export `Images/Dashboard Preview.png` from the built workbook.

Method: print the Dashboard sheet to PDF (Excel's own renderer, no clipboard
involved), then rasterise page 1 with PyMuPDF. The clipboard route
(CopyPicture -> Chart.Paste -> Chart.Export) is unreliable when Excel runs
non-interactively - it silently yields a blank frame because there is no
active window to own the clipboard.

Run: python Scripts/05_export_preview.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import win32com.client as win32

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
WB = ROOT / "Excel Dashboard" / "Blinkit Dashboard.xlsx"
IMG_DIR = ROOT / "Images"
IMG_DIR.mkdir(parents=True, exist_ok=True)
OUT = IMG_DIR / "Dashboard Preview.png"
TMP_PDF = IMG_DIR / "_dashboard_tmp.pdf"

ZOOM = 2.0          # 2x for a crisp README image


def dispatch_excel(retries: int = 6):
    for attempt in range(retries):
        try:
            return win32.gencache.EnsureDispatch("Excel.Application")
        except Exception as exc:
            print(f"  [retry {attempt+1}/{retries}] {str(exc)[:60]}")
            time.sleep(4)
    raise RuntimeError("Could not start Excel.")


def main() -> None:
    if not WB.exists():
        raise SystemExit(f"missing workbook: {WB}\nRun 04_build_dashboard.py first.")

    excel = dispatch_excel()
    excel.Visible = False
    excel.DisplayAlerts = False

    wb = None
    try:
        wb = excel.Workbooks.Open(str(WB))
        ws = wb.Sheets("Dashboard")
        ws.Activate()

        # Fit the whole dashboard onto one landscape page.
        ps = ws.PageSetup
        ps.Orientation = 2            # xlLandscape
        ps.Zoom = False               # required before FitToPages takes effect
        ps.FitToPagesWide = 1
        ps.FitToPagesTall = 1
        # Use the range the builder measured from real object geometry. A
        # hardcoded range here silently clips whatever sits below it.
        try:
            ps.PrintArea = wb.Names("DashboardCapture").RefersToRange.Address
        except Exception:
            ps.PrintArea = "$A$1:$R$75"
        print(f"[range] {ps.PrintArea}")
        for attr in ("LeftMargin", "RightMargin", "TopMargin", "BottomMargin"):
            setattr(ps, attr, 12)

        if TMP_PDF.exists():
            TMP_PDF.unlink()
        ws.ExportAsFixedFormat(Type=0, Filename=str(TMP_PDF), Quality=0)
        print(f"[pdf] {TMP_PDF.name} exported")

    finally:
        if wb is not None:
            try:
                wb.Close(SaveChanges=False)
            except Exception:
                pass
        try:
            excel.Quit()
        except Exception:
            pass

    # ---- rasterise ------------------------------------------------------
    import fitz          # PyMuPDF

    doc = fitz.open(TMP_PDF)
    page = doc[0]
    pix = page.get_pixmap(matrix=fitz.Matrix(ZOOM, ZOOM))
    pix.save(OUT)
    doc.close()
    TMP_PDF.unlink(missing_ok=True)

    print(f"[saved] {OUT}  {pix.width}x{pix.height}px  "
          f"({OUT.stat().st_size/1024:.0f} KB)")


if __name__ == "__main__":
    main()
