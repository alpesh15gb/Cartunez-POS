# GoFrugal retail workflow audit

On 20 November 2026, REA loaded three published GoFrugal operator guides in Chrome and captured their rendered accessibility trees. The locally available RetailEasy directories contained setup and licensing records. A running GoFrugal till and a signed-in cloud tenant were unavailable. The observations below describe the vendor's documented operator workflows.

| Operator task | What the rendered guide showed | REA browser capture |
| --- | --- | --- |
| Receive and label a delivery | Staff can link a supplier invoice to a purchase order or receipt, scan incoming goods, and select purchased items for barcode printing. This keeps the labeling decision with the delivery being processed. [Purchase invoice guide](https://community.gofrugal.com/portal/en/kb/gofrugalretaileasyoncloud/purchase/purchase-order/articles/how-to-create-a-purchase-invoice-in-retaileasy-on-cloud-9-6-2022-2) | `ev_648ef34b2e19ebc99ccee5e7970f297b475dc8625540f2e13ccfad681914d0fe` |
| Park a sale and recall it | The cashier can hold a bill, resume it, or clear it. The guide describes stock reservation while a bill is parked. [Hold and recall guide](https://community.gofrugal.com/portal/en/kb/gofrugalretaileasyoncloud/sales-management/sales-bill/articles/how-to-1-11-2025-1) | `ev_48ba5ea09536543a6602984fa7c4e810703ed91168c7fb809d588c2308997c80` |
| Record a till withdrawal | The cashier selects the bank-drop ledger, enters the amount and saves. Supervisors can review withdrawals by cashier. [Cash withdrawal guide](https://community.gofrugal.com/portal/en/kb/gofrugalretaileasy/sales/cash-and-shift-management/articles/cash-withdrawal-in-cashier-management) | `ev_e9f0e66269631b8ed7ee52c1e5cb5976e08c8876acf193ba6dcf150b026a4620` |

## Implications for Cartunez

* Purchasing already records individual deliveries with the part, quantity and destination bin. Before this audit, printing from the catalog required the receiver to reconstruct these details. If an order of ten arrives in deliveries of six and four, the second delivery should offer four labels, even after stock moves to another bin. A reprint should identify the original delivery and let staff omit a line or print fewer copies.
* Parked sales should retain their reserved quantities across a reload, release them on cancellation, and consume them once at checkout. These are practical acceptance checks for competing counters.
* A withdrawal needs a reason, amount, operator and shift. Closing a shift should include bank drops in expected drawer cash without changing sales revenue.
* GoFrugal also documents stock-count review by location and item, and a check for transactions since counting. For Cartunez, an important concurrency case is a sale between entering a count and approving it. [Stock update detail guide](https://community.gofrugal.com/portal/en/kb/gofrugalretaileasyoncloud/inventorymanagement/price-fixing/price-fixing-markup-markdown/articles/how-to-check-the-stock-update-detail-in-retaileasy-on-cloud)

## Delivery labels in Cartunez

Open **Purchasing → Orders**, use **Print receipt labels** on a partially or fully received order, and choose the delivery. Each line starts with its received units and original destination bin. Enter zero to skip a line or reduce the quantity for a reprint. The design, price and barcode come from the current shop and catalog settings.

The API acceptance test checks a receipt retry and two deliveries into different bins. A Flutter widget test opens Purchasing, selects one of two receipts, checks both defaults, rejects an overprint, skips a line and sends the remaining two copies to a loopback Zebra receiver. Separate ZPL tests cover single-column quantities and partially filled multi-column rows. These checks exercise the print data produced by the app. Physical print quality and device-camera scanning need a counter-side check with the shop's printer, label stock and scanner.
