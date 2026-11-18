# Cartunez POS audit

## Live walkthrough

On 18 November 2026, the owner account was used to walk the published web app through initial part, bin and supplier setup, stock adjustment, barcode lookup, cash checkout, receipt review, a partial return, shift close, sales reporting, purchase ordering and receiving. A keyboard-entry scan with an Enter suffix added the oil filter, and a repeated scan increased the quantity. The two-unit ₹500 test invoice accepted ₹600 and showed ₹100 change. The ₹250 credit note restored one unit to the sellable bin. The shift closed with ₹250 expected and counted, and the sales report showed ₹250 net. The purchase order received one more unit into the same bin.

The live audit created the `AUDIT TEST` part, supplier and bin, invoice `INV-MAIN-1`, credit note `CR-MAIN-1`, a completed shift and a received test purchase order. These are test records for the owner’s reset.

## Release verification

The 1.0.1 web release and Windows x64 portable package were built locally. The Flutter unit suite, API suites and the retail acceptance suite against PostgreSQL 17 passed. The rebuilt web client was exercised at desktop and phone sizes, including UPC/EAN equivalence, GS1 Digital Link, checkout, part and bin scan selection, a negative inventory adjustment, camera-error fallback and CSV export. Native hardware and the production rollout remain pending.

## Fixed in 1.0.1

| Area | Change |
| --- | --- |
| First-run workflows | Billing links directly to shifts and parts. Inventory and purchasing show the prerequisites for a stock operation or purchase. |
| Billing | A scan adds one unit immediately when there is one suitable bin and the item needs no serial number or fitment approval. Repeated scans respect remaining stock. Forms and checkout prevent concurrent submission. |
| Barcode capture | Keyboard-mode USB and Bluetooth, manual entry, and supported cameras share a capture flow. Staff can use scans to choose parts and bins in inventory and purchasing. |
| Barcode identity | Exact private codes preserve punctuation. Valid UPC and EAN representations share a GTIN identity. Recognized GS1 element strings and Digital Links extract the product GTIN. The server rejects new catalog collisions. New internal labels use Code 128, and older labels stay resolvable. |
| Stock and labels | Negative adjustments work through the form. Label generation reserves quiet zones and identifies unprintable codes. Inventory and shift tables have room for status and amounts. |
| Reporting | INR reports use IST days. Daily sales, tender movements and GST components reconcile against posted records. Reports read a consistent database snapshot, expose applicable filters, paginate displayed results and export all matching rows. |

## Remaining rollout work

1. Verify physical USB and Bluetooth scanners, Android and browser cameras, and 50 × 30 mm thermal labels with the actual hardware at each counter. The desktop Windows build uses keyboard-mode scanners. Windows users can use the web app for webcam scanning. A browser test verified the camera-error fallback and keyboard capture. The Android release build needs the SDK command-line tools, NDK 28.2 and license acceptance on the build machine.
2. Configure and review the actual business, branch, tax profile and receipt layout. Cartunez calculates supported GST components and issues linked credit notes. If the business needs IRN, signed QR codes, e-way bills or GST filing, those need a provider integration and accountant validation. [CBIC invoice rules](https://cbic-gst.gov.in/gst-invoice-rules.html) · [Zoho e-invoicing](https://www.zoho.com/in/invoice/gst-einvoicing/)
3. Add automated Card and UPI settlement imports, refund-provider references, and register paid-in/paid-out entries. Current tender reports reconcile POS entries. Provider payout reconciliation and cash movements such as safe drops need their own records. [Square reconciliation and payment reports](https://squareup.com/help/us/en/article/5381-in-app-summaries-and-reports) · [Shopify cash tracking](https://help.shopify.com/en/manual/sell-in-person/shopify-pos/cash-register-management)
4. Add a validated catalog import, multi-line purchasing and receiving screens, and server-side report pagination before high-volume rollout. Stock valuation currently uses catalog cost. Historical valuation, landed-cost costing, batch tracking and consolidated branch reporting require additional ledger and reporting work. [GoFrugal RetailEasy](https://www.gofrugal.com/cloud/retail-pos.html)
5. Decide which supplier labels need more than product identification. GS1 lot, expiry, serial and variable-weight fields require dedicated rules before they can drive receiving or billing. [GS1 retail POS barcode guideline](https://ref.gs1.org/guidelines/2d-in-retail/)
