"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  emptyCart,
  fitment,
  initializeNative,
  installationKey,
  locked,
  normalize,
  quote,
  readLocal,
  request,
  scopeKey,
  writeLocal,
  gs1Valid,
  barcodeFormat,
  inStoreBarcode,
  type Json,
  type Session,
  type Workspace,
} from "./storage";
import JsBarcode from "jsbarcode";

type Role = "owner" | "manager" | "cashier" | "inventory";
const everyone: Role[] = ["owner", "manager", "cashier", "inventory"];
const sellers: Role[] = ["owner", "manager", "cashier"];
const stockRoles: Role[] = ["owner", "manager", "inventory"];
type Feature = "transfers" | "fitment" | "offline" | "warranty";
type Tab = { name: string; label: string; roles: Role[]; feature?: Feature };
/** Eight menu areas; related screens are tabs inside them. */
const navItems: { label: string; icon: string; tabs: Tab[] }[] = [
  { label: "Billing", icon: "icon-register", tabs: [{ name: "Billing", label: "Billing", roles: sellers }] },
  {
    label: "Sales",
    icon: "icon-receipt",
    tabs: [
      { name: "Sales history", label: "Invoices", roles: sellers },
      { name: "Shifts", label: "Shifts", roles: sellers },
    ],
  },
  { label: "Customers", icon: "icon-person", tabs: [{ name: "Customers", label: "Customers", roles: sellers }] },
  {
    label: "Inventory",
    icon: "icon-box",
    tabs: [
      { name: "Inventory", label: "Parts", roles: everyone },
      { name: "Locations", label: "Bins", roles: stockRoles },
      { name: "Fitment", label: "Fitment", roles: stockRoles, feature: "fitment" },
      { name: "Transfers", label: "Transfers", roles: stockRoles, feature: "transfers" },
      { name: "Warranty & cores", label: "Warranty & cores", roles: stockRoles, feature: "warranty" },
    ],
  },
  {
    label: "Purchasing",
    icon: "icon-car",
    tabs: [
      { name: "Purchasing", label: "Orders", roles: stockRoles },
      { name: "Suppliers", label: "Suppliers", roles: stockRoles },
    ],
  },
  { label: "Dashboard", icon: "icon-chart", tabs: [{ name: "Dashboard", label: "Dashboard", roles: everyone }] },
  { label: "Reports", icon: "icon-chart", tabs: [{ name: "Reports", label: "Reports", roles: stockRoles }] },
  {
    label: "Settings",
    icon: "icon-person",
    tabs: [
      { name: "Settings", label: "Settings", roles: everyone },
      { name: "Reconciliation", label: "Sync & audit", roles: sellers },
    ],
  },
];
const tabsFor = (tabs: Tab[], role?: string, features?: Record<Feature, boolean>) =>
  tabs.filter(
    (tab) => tab.roles.includes(role as Role) && (!tab.feature || features?.[tab.feature] !== false),
  );
const sectionsFor = (role?: string, features?: Record<Feature, boolean>) =>
  navItems.flatMap((item) => tabsFor(item.tabs, role, features).map((tab) => tab.name));
const sectionHelp: Record<string, string> = {
  Billing: "Scan or pick parts, then take payment.",
  "Sales history": "Reprint receipts, take returns and void invoices.",
  Shifts: "Open and close the cash drawer for each cashier.",
  Customers: "Saved customers for receipts and GST invoices.",
  Inventory: "Parts, prices, stock and labels.",
  Locations: "Racks and bins where stock is kept.",
  Fitment: "Which vehicles each part fits.",
  Transfers: "Stock sent between branches.",
  "Warranty & cores": "Supplier warranty claims and core deposit refunds.",
  Purchasing: "Order from suppliers and receive goods into bins.",
  Suppliers: "Companies you buy parts from.",
  Dashboard: "Today at a glance.",
  Reports: "Sales, stock and tax reports with CSV export.",
  Settings: "Business details, staff and this counter.",
  Reconciliation: "Sales waiting to sync and the audit trail.",
};
const inventoryReports = [
  "valuation",
  "stock-by-bin",
  "stock-movement",
  "low-stock",
  "fast-moving",
  "slow-moving",
  "aging",
  "purchase-receipts",
  "warranty",
];
const moneyKeys = new Set([
  "gross",
  "returns",
  "coreReturns",
  "net",
  "discount",
  "tax",
  "cost",
  "margin",
  "value",
  "landedCost",
  "total",
  "openingCash",
  "expectedCash",
  "countedCash",
  "variance",
  "collected",
  "refunded",
  "charged",
  "outstanding",
  "revenue",
  "amount",
  "taxable",
  "unitPrice",
  "subtotal",
  "coreCharge",
  "rounding",
  "price",
  "retailPrice",
  "wholesalePrice",
]);
const hiddenReportKeys = new Set([
  "id",
  "invoiceId",
  "productId",
  "returnId",
  "purchaseOrderId",
  "supplierId",
  "lineId",
  "binId",
]);
const humanize = (key: string) =>
  key
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[-_]/g, " ")
    .replace(/^./, (letter) => letter.toUpperCase());
const titleCase = (value: string) =>
  value ? value[0].toUpperCase() + value.slice(1) : value;
const reportNames = [
  "sales",
  "returns",
  "discounts",
  "margin",
  "shifts",
  "tenders",
  "valuation",
  "stock-by-bin",
  "stock-movement",
  "low-stock",
  "fast-moving",
  "slow-moving",
  "aging",
  "purchase-receipts",
  "tax",
  "warranty",
  "cores",
  "fitment",
];
type Field = {
  name: string;
  label: string;
  type?: string;
  value?: any;
  options?: { value: string; label: string }[];
  required?: boolean;
  min?: number;
  step?: string;
  help?: string;
  /** Rarely used fields are tucked under "More options". */
  advanced?: boolean;
  /** Offer earlier values while still allowing a new one. */
  suggestions?: string[];
};
type Modal = {
  title: string;
  fields?: Field[];
  content?: React.ReactNode;
  submit?: string;
  action?: (data: Json) => Promise<void>;
  wide?: boolean;
  /** Open "More options" initially, for example when editing an existing record. */
  expanded?: boolean;
};
const options = (
  records: Json[],
  label: (item: Json) => string = (item) => item.name || item.number || item.id,
) => records.map((item) => ({ value: item.id, label: label(item) }));
const list = (value: any) =>
  String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
const formatDate = (value: string) =>
  value ? new Date(value).toLocaleString("en-IN") : "—";
const binName = (bin: Json) =>
  [bin.area, bin.rack, bin.shelf, bin.bin].filter(Boolean).join(" / ");
const deviceKey = (session: Session) =>
  `server:${installationKey(session)}:device:${session.organizationId}:${session.branchId}`;
function FieldInput({ field }: { field: Field }) {
  if (field.type === "checks")
    return (
      <fieldset className="field check-group">
        <legend>{field.label}</legend>
        <div>
          {(field.options || []).map((option) => (
            <label className="check-field" key={option.value}>
              <input
                type="checkbox"
                name={field.name}
                value={option.value}
                defaultChecked={(field.value || []).includes(option.value)}
              />
              {option.label}
            </label>
          ))}
        </div>
        {field.help && <small>{field.help}</small>}
      </fieldset>
    );
  return (
    <label className="field">
      <span>{field.label}</span>
      {field.type === "textarea" ? (
        <textarea
          name={field.name}
          defaultValue={field.value ?? ""}
          required={field.required}
          rows={5}
        />
      ) : field.options ? (
        <select
          name={field.name}
          defaultValue={field.value ?? ""}
          required={field.required}
        >
          <option value="">Select…</option>
          {field.options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      ) : (
        <>
          <input
            name={field.name}
            type={field.type || "text"}
            defaultValue={field.value ?? ""}
            required={field.required}
            min={field.min}
            step={field.step || (field.type === "number" ? "1" : undefined)}
            list={field.suggestions?.length ? `${field.name}-suggestions` : undefined}
          />
          {!!field.suggestions?.length && (
            <datalist id={`${field.name}-suggestions`}>
              {field.suggestions.map((value) => (
                <option key={value} value={value} />
              ))}
            </datalist>
          )}
        </>
      )}
      {field.help && <small>{field.help}</small>}
    </label>
  );
}
function DataTable({
  rows,
  columns,
  action,
}: {
  rows: Json[];
  columns: [string, (item: Json) => React.ReactNode][];
  action?: (item: Json) => React.ReactNode;
}) {
  return rows.length ? (
    <div className="table-scroll">
      <table className="data-table">
        <thead>
          <tr>
            {columns.map(([label]) => (
              <th key={label}>{label}</th>
            ))}
            {action && <th>Actions</th>}
          </tr>
        </thead>
        <tbody>
          {rows.map((item, index) => (
            <tr key={item.id || index}>
              {columns.map(([label, render]) => (
                <td key={label}>{render(item)}</td>
              ))}
              {action && (
                <td>
                  <div className="table-actions">{action(item)}</div>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  ) : (
    <div className="empty-state">
      <strong>No records yet</strong>
      <p>New activity will appear here.</p>
    </div>
  );
}

function CheckoutFields({
  total,
  tenders,
  money,
  gst,
  placeOfSupply,
}: {
  total: number;
  tenders: string[];
  money: (amount: number) => string;
  gst: boolean;
  placeOfSupply: string;
}) {
  const first = tenders.includes("Cash") ? "Cash" : tenders[0];
  const [tender, setTender] = useState(first);
  const [amount, setAmount] = useState((total / 100).toFixed(2));
  const [split, setSplit] = useState(false);
  const [secondTender, setSecondTender] = useState(
    tenders.find((type) => type !== first) || first,
  );
  const [secondAmount, setSecondAmount] = useState("0.00");
  const minor = (value: string) => Math.round((Number(value) || 0) * 100);
  const paid = minor(amount) + (split ? minor(secondAmount) : 0);
  const cash =
    (tender === "Cash" ? minor(amount) : 0) +
    (split && secondTender === "Cash" ? minor(secondAmount) : 0);
  const due = total - paid;
  const change = Math.max(0, paid - total);
  const nonCash = tender !== "Cash" || (split && secondTender !== "Cash");
  const quick = [
    total,
    ...[10000, 20000, 50000, 200000]
      .map((step) => Math.ceil(total / step) * step)
      .filter((value) => value > total),
  ].filter((value, index, all) => all.indexOf(value) === index).slice(0, 4);
  return (
    <div className="checkout-fields">
      <div className="tender-choice" role="radiogroup" aria-label="Payment type">
        {tenders.map((type) => (
          <button
            type="button"
            key={type}
            role="radio"
            aria-checked={tender === type}
            className={`tender-option ${tender === type ? "is-active" : ""}`}
            onClick={() => setTender(type)}
          >
            {type}
          </button>
        ))}
      </div>
      <input type="hidden" name="tender" value={tender} />
      <label className="field">
        <span>{split ? `${tender} amount` : "Amount received"}</span>
        <input
          name="amount"
          type="number"
          min={0}
          step="0.01"
          required
          value={amount}
          onChange={(event) => setAmount(event.target.value)}
          autoFocus
        />
      </label>
      {tender === "Cash" && !split && (
        <div className="quick-cash">
          {quick.map((value) => (
            <button
              type="button"
              className="button"
              key={value}
              onClick={() => setAmount((value / 100).toFixed(2))}
            >
              {value === total ? "Exact" : money(value)}
            </button>
          ))}
        </div>
      )}
      {tenders.length > 1 && (
        <button
          type="button"
          className="text-button split-toggle"
          onClick={() => {
            if (split) setSecondAmount("0.00");
            else {
              setSecondAmount((Math.max(0, total - minor(amount)) / 100).toFixed(2));
            }
            setSplit(!split);
          }}
        >
          {split ? "Remove split payment" : "Split payment"}
        </button>
      )}
      {split && (
        <div className="editor-grid">
          <label className="field">
            <span>Second payment type</span>
            <select
              name="secondTender"
              value={secondTender}
              onChange={(event) => setSecondTender(event.target.value)}
            >
              {tenders.map((type) => (
                <option key={type} value={type}>
                  {type}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Second amount</span>
            <input
              name="secondAmount"
              type="number"
              min={0}
              step="0.01"
              value={secondAmount}
              onChange={(event) => setSecondAmount(event.target.value)}
            />
          </label>
        </div>
      )}
      {nonCash && (
        <div className="editor-grid">
          <label className="field">
            <span>Card / UPI confirmation</span>
            <select name="confirmed" defaultValue="no">
              <option value="no">Awaiting provider confirmation</option>
              <option value="yes">Confirmed by provider</option>
            </select>
          </label>
          <label className="field">
            <span>Provider reference</span>
            <input name="reference" autoComplete="off" />
          </label>
        </div>
      )}
      <label className="field">
        <span>{gst ? "Place of supply state code" : "Place of supply (optional)"}</span>
        <input
          name="placeOfSupply"
          defaultValue={placeOfSupply}
          required={gst}
          inputMode={gst ? "numeric" : undefined}
        />
        {gst && <small>Confirm the two-digit state code for this supply.</small>}
      </label>
      <dl className="checkout-due">
        <div>
          <dt>Total payable</dt>
          <dd>{money(total)}</dd>
        </div>
        <div>
          <dt>Paid</dt>
          <dd>{money(paid)}</dd>
        </div>
        <div className={due > 0 ? "is-due" : change > cash ? "is-due" : "is-change"}>
          <dt>{due > 0 ? "Still due" : "Change to return"}</dt>
          <dd>{money(due > 0 ? due : change)}</dd>
        </div>
      </dl>
      {change > cash && (
        <p className="form-hint">Change can only be returned from cash received.</p>
      )}
    </div>
  );
}

function Barcode({ value, height = 55 }: { value: string; height?: number }) {
  const element = useRef<SVGSVGElement>(null);
  const [invalid, setInvalid] = useState(false);
  useEffect(() => {
    if (!element.current) return;
    const options = { height, width: 1.5, fontSize: 13, margin: 8 };
    try {
      JsBarcode(element.current, value, { ...options, format: barcodeFormat(value) });
      setInvalid(false);
    } catch {
      try {
        JsBarcode(element.current, value, { ...options, format: "CODE128" });
        setInvalid(false);
      } catch {
        setInvalid(true);
      }
    }
  }, [value, height]);
  return invalid ? (
    <p className="form-error">“{value}” cannot be printed as a barcode. Use letters, numbers and basic symbols.</p>
  ) : (
    <svg ref={element} aria-label={`Barcode ${value}`} />
  );
}

type LabelItem = { name: string; code: string; sku?: string; price?: number };
function LabelSheet({
  items,
  money,
  print,
}: {
  items: LabelItem[];
  money: (amount: number) => string;
  print: () => void;
}) {
  const [copies, setCopies] = useState(1);
  const [showPrice, setShowPrice] = useState(items.some((item) => item.price !== undefined));
  const count = Math.min(100, Math.max(1, Math.floor(copies) || 1));
  return (
    <div className="label-sheet">
      <div className="label-options no-print">
        <label className="field">
          <span>Copies of each label</span>
          <input
            type="number"
            min={1}
            max={100}
            value={copies}
            onChange={(event) => setCopies(Number(event.target.value))}
          />
        </label>
        {items.some((item) => item.price !== undefined) && (
          <label className="check-field">
            <input
              type="checkbox"
              checked={showPrice}
              onChange={(event) => setShowPrice(event.target.checked)}
            />
            Show retail price
          </label>
        )}
        <p className="form-hint">
          {items.length * count} label{items.length * count === 1 ? "" : "s"} sized 50 × 30 mm.
          Choose the label printer and paper size in the print dialog.
        </p>
      </div>
      <div className="label-grid">
        {items.flatMap((item, index) =>
          Array.from({ length: count }, (_, copy) => (
            <div className="barcode-label-card" key={`${index}-${copy}`}>
              <strong>{item.name}</strong>
              <Barcode value={item.code} height={40} />
              <div className="label-meta">
                {item.sku && <span>{item.sku}</span>}
                {showPrice && item.price !== undefined && <b>{money(item.price)}</b>}
              </div>
            </div>
          )),
        )}
      </div>
      <div className="dialog-actions no-print">
        <button type="button" className="primary-button" onClick={print}>
          Print labels
        </button>
      </div>
    </div>
  );
}

function CameraScanner({ onCode }: { onCode: (code: string) => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const callback = useRef(onCode);
  callback.current = onCode;
  const [message, setMessage] = useState("Starting camera…");
  useEffect(() => {
    let stream: MediaStream | undefined;
    let stopped = false;
    let timer: number | undefined;
    (async () => {
      try {
        const Detector = (window as any).BarcodeDetector;
        if (!Detector || !navigator.mediaDevices?.getUserMedia)
          throw new Error("unsupported");
        const formats: string[] = (await Detector.getSupportedFormats?.()) || [];
        const detector = new Detector(formats.length ? { formats } : undefined);
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: { ideal: "environment" } },
          audio: false,
        });
        if (stopped || !video.current) return;
        video.current.srcObject = stream;
        await video.current.play();
        setMessage("Hold the barcode inside the frame.");
        const tick = async () => {
          if (stopped || !video.current) return;
          try {
            const found = await detector.detect(video.current);
            const code = found.find((item: Json) => item.rawValue)?.rawValue;
            if (code) {
              stopped = true;
              callback.current(String(code).trim());
              return;
            }
          } catch {
            /* A frame may not be ready yet. */
          }
          timer = window.setTimeout(tick, 180);
        };
        void tick();
      } catch (reason: any) {
        setMessage(
          reason?.name === "NotAllowedError"
            ? "Camera permission was denied. Allow camera access for this site, or use a USB/Bluetooth scanner."
            : reason?.message === "unsupported"
              ? "This browser cannot read barcodes from the camera. Use a USB/Bluetooth scanner or type the code."
              : "The camera could not be opened. Check that no other app is using it.",
        );
      }
    })();
    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      stream?.getTracks().forEach((track) => track.stop());
    };
  }, []);
  return (
    <div className="camera-scanner">
      <div className="camera-frame">
        <video ref={video} muted playsInline />
        <span className="camera-target" aria-hidden="true" />
      </div>
      <p role="status">{message}</p>
    </div>
  );
}
export default function Register() {
  const [session, setSession] = useState<Session | null>(null);
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [ready, setReady] = useState(false);
  const [online, setOnline] = useState(false);
  const [section, setSection] = useState("Billing");
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("All parts");
  const [cart, setCart] = useState<Json | null>(null);
  const [modal, setModal] = useState<Modal | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [report, setReport] = useState<Json | null>(null);
  const [receipt, setReceipt] = useState<Json | null>(null);
  const [connection, setConnection] = useState<Json>({});
  const dialogRef = useRef<HTMLDialogElement>(null);
  const syncBusy = useRef(false);
  const resumeCheckout = useRef(false);
  const scanBuffer = useRef({ text: "", last: 0 });
  const [cameraScan, setCameraScan] = useState(false);
  const handleScanRef = useRef<(code: string) => void>(() => {});
  handleScanRef.current = handleScan;
  const snapshot = workspace?.snapshot || {};
  const products: Json[] = snapshot.products || [];
  const bins: Json[] = snapshot.locations || [];
  const stock: Json[] = snapshot.stock || [];
  const role = session?.user.role;
  const manager = role === "owner" || role === "manager";
  const inventoryRole = manager || role === "inventory";
  const canSell = manager || role === "cashier";
  const features = {
    transfers: true,
    fitment: true,
    offline: true,
    warranty: true,
    ...(snapshot.settings?.features || {}),
  } as Record<Feature, boolean>;
  const allowedSections = sectionsFor(role, features);
  const userName = (id?: string) => {
    if (!id) return "—";
    if (id === session?.user.id) return session.user.name || session.user.email;
    const user = (snapshot.users || []).find((item: Json) => item.id === id);
    return user?.name || user?.email || id;
  };
  const branchLabel = (id?: string) =>
    (snapshot.branches || []).find((branch: Json) => branch.id === id)?.name ||
    id ||
    "—";
  const invoiceReturns = (invoiceId: string): Json[] =>
    (snapshot.returns || []).filter(
      (item: Json) => item.invoiceId === invoiceId,
    );
  const invoiceStatus = (invoice: Json) => {
    const credits = invoiceReturns(invoice.id);
    if (credits.some((item) => item.voided)) return "Voided";
    if (!credits.length) return invoice.status || "Finalized";
    const returned = credits
      .flatMap((item) => item.lines || [])
      .reduce((sum: number, line: Json) => sum + (line.quantity || 0), 0);
    const sold = (invoice.lines || []).reduce(
      (sum: number, line: Json) => sum + (line.qty || 0),
      0,
    );
    return returned >= sold ? "Returned" : "Partially returned";
  };
  const returnedQuantity = (invoice: Json, lineId: string) =>
    invoiceReturns(invoice.id)
      .flatMap((item) => item.lines || [])
      .filter((line: Json) => line.lineId === lineId)
      .reduce((sum: number, line: Json) => sum + (line.quantity || 0), 0);
  const tenderTypes: string[] = snapshot.settings?.tenderTypes || [
    "Cash",
    "Card",
    "UPI",
  ];
  const money =(amount: number, currency = snapshot.settings?.currency || "INR") =>
    new Intl.NumberFormat("en-IN", {
      style: "currency",
      currency,
    }).format((amount || 0) / 100);
  const productName = (id: string) =>
    products.find((product) => product.id === id)?.name || id;
  const locationName = (id: string) =>
    bins.find((bin) => bin.id === id)
      ? binName(bins.find((bin) => bin.id === id)!)
      : id;
  const openSection = (name: string) => {
    setSection(name);
    setSearch("");
    setError("");
    setReport(null);
  };
  const currentNav = navItems.find((item) => item.tabs.some((tab) => tab.name === section));
  const currentTabs = currentNav ? tabsFor(currentNav.tabs, role, features) : [];
  const updateCart = (changes: Json) =>
    setCart((value) => ({ ...value, ...changes }));
  const toast = (message: string) => {
    setNotice(message);
    setTimeout(() => setNotice(""), 6000);
  };
  const fail = (reason: unknown) =>
    setError(reason instanceof Error ? reason.message : String(reason));
  const api = async (path: string, data?: unknown, method?: string) => {
    if (!session) throw new Error("Sign in to continue.");
    return request(session, path, data, method);
  };
  const persistWorkspace = async (value: Workspace) => {
    if (!session) return;
    await writeLocal(scopeKey(session), value);
    setWorkspace(value);
  };

  const synchronize = useCallback(async (active: Session) => {
    if (syncBusy.current) return;
    syncBusy.current = true;
    try {
      await locked(deviceKey(active), async () => {
        const previous = await readLocal<Workspace>(scopeKey(active));
        let pending = previous?.pending || [];
        const onlinePending = pending.filter(
          (item) =>
            !item.transaction.offline &&
            item.status !== "awaiting-payment" &&
            !item.error,
        );
        for (const item of onlinePending) {
          try {
            await request(active, "/invoices", item.transaction);
            pending = pending.filter(
              (entry) =>
                entry.transaction.transactionId !==
                item.transaction.transactionId,
            );
          } catch (reason) {
            if (
              reason instanceof ApiError &&
              reason.status >= 400 &&
              reason.status < 500 &&
              reason.status !== 401
            )
              item.error = reason.message;
            else throw reason;
          }
        }
        const devices = new Set(
          pending
            .filter((item) => item.transaction.offline)
            .map((item) => item.transaction.deviceId),
        );
        for (const deviceId of devices) {
          const result = await request(active, "/sync", {
            deviceId,
            transactions: pending
              .filter(
                (item) =>
                  item.transaction.offline &&
                  item.transaction.deviceId === deviceId,
              )
              .map((item) => item.transaction),
          });
          const results = Array.isArray(result)
            ? result
            : result.results || result.transactions || [];
          pending = pending.filter((item) => {
            const status = results.find(
              (entry: Json) =>
                entry.transactionId === item.transaction.transactionId,
            );
            if (status?.status === "rejected")
              item.error =
                status.error ||
                "Server rejected this transaction. Manager review required.";
            return (
              !status ||
              ![
                "accepted",
                "synced",
                "completed",
                "duplicate",
                "conflict",
                "finalized",
              ].includes(status.status)
            );
          });
        }
        const nextSnapshot = await request(active, "/bootstrap");
        const refreshed = {
          ...active,
          user: { ...active.user, ...nextSnapshot.user },
        };
        await writeLocal("active-session", refreshed);
        setSession((current) =>
          current && current.user.role !== refreshed.user.role
            ? refreshed
            : current,
        );
        const enrollment = await readLocal<Json>(deviceKey(active));
        const deviceId = enrollment?.device?.id || previous?.device?.id;
        const device =
          (nextSnapshot.devices || []).find(
            (item: Json) => item.id === deviceId,
          ) || null;
        if (device && enrollment)
          await writeLocal(deviceKey(active), { ...enrollment, device });
        const next: Workspace = {
          snapshot: nextSnapshot,
          pending,
          device,
          nextInvoice: enrollment?.nextInvoice ?? previous?.nextInvoice ?? 0,
          lastSync: new Date().toISOString(),
          cart: previous?.cart,
        };
        await writeLocal(scopeKey(active), next);
        setWorkspace(next);
        setOnline(true);
      });
    } catch (reason) {
      setOnline(false);
      if (reason instanceof ApiError && reason.status === 401)
        setError(
          "Session expired. Sign in again to synchronize. Your pending sales remain on this device.",
        );
    } finally {
      syncBusy.current = false;
    }
  }, []);

  useEffect(() => {
    (async () => {
      await initializeNative();
      const storedConnection = await readLocal<Json>("connection-profile");
      const browserOrigin = !window.motorlineNative && ["http:", "https:"].includes(location.protocol);
      let installation: Json = {};
      if (browserOrigin) {
        try {
          const response = await fetch("/installation.json", {cache:"no-store", signal:AbortSignal.timeout(2000)});
          if (response.ok && response.headers.get("content-type")?.includes("json")) installation = await response.json();
        } catch { /* A saved connection remains available offline. */ }
      }
      const loopbackDemo = browserOrigin && ["localhost", "127.0.0.1"].includes(location.hostname) && location.port === "3000";
      setConnection({
        api: installation.apiUrl || process.env.NEXT_PUBLIC_API_URL || (browserOrigin && !loopbackDemo ? `${location.origin}/api/v1` : "http://127.0.0.1:4000/api/v1"),
        organizationId: installation.organizationId || (loopbackDemo ? "demo" : ""),
        branchId: installation.branchId || (loopbackDemo ? "pune" : ""),
        ...storedConnection,
      });
      const active = await readLocal<Session>("active-session");
      if (active) {
        const saved = await readLocal<Workspace>(scopeKey(active));
        if (saved) {
          setSession(active);
          setWorkspace(saved);
          setCart(saved.cart || emptyCart());
          setReady(true);
          void synchronize(active);
        }
      }
      setReady(true);
      if (
        "serviceWorker" in navigator &&
        !window.motorlineNative &&
        location.protocol !== "file:"
      )
        navigator.serviceWorker.register("/sw.js").catch(() => {});
    })().catch((reason) => {
      fail(reason);
      setReady(true);
    });
  }, [synchronize]);

  useEffect(() => {
    if (!session) return;
    const sync = () => {
      void synchronize(session);
    };
    const offline = () => setOnline(false);
    const timer = setInterval(sync, 15000);
    window.addEventListener("online", sync);
    window.addEventListener("offline", offline);
    return () => {
      clearInterval(timer);
      window.removeEventListener("online", sync);
      window.removeEventListener("offline", offline);
    };
  }, [session, synchronize]);

  useEffect(() => {
    if (!session || !cart) return;
    const timer = setTimeout(() => {
      void locked(deviceKey(session), async () => {
        const value = await readLocal<Workspace>(scopeKey(session));
        if (value) await writeLocal(scopeKey(session), { ...value, cart });
      }).catch(fail);
    }, 200);
    return () => clearTimeout(timer);
  }, [cart, session]);

  useEffect(() => {
    if (modal || receipt) dialogRef.current?.showModal();
    else dialogRef.current?.close();
  }, [modal, receipt]);
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (dialogRef.current?.open) return;
      // Keyboard-wedge scanners type very quickly and finish with Enter. Capture
      // them even when no field has focus so a scan is never lost.
      const target = event.target as HTMLElement | null;
      const typing = target?.closest?.("input, textarea, select, [contenteditable]");
      if (!typing && session && !event.ctrlKey && !event.metaKey && !event.altKey) {
        const now = performance.now();
        const buffer = scanBuffer.current;
        if (now - buffer.last > 100) buffer.text = "";
        buffer.last = now;
        if (event.key === "Enter") {
          if (buffer.text.length >= 3) {
            event.preventDefault();
            const code = buffer.text;
            buffer.text = "";
            handleScan(code);
            return;
          }
          buffer.text = "";
        } else if (event.key.length === 1) buffer.text += event.key;
      }
      if (event.key === "F2") {
        event.preventDefault();
        document.getElementById("global-search")?.focus();
      }
      if (event.key === "F6" && section === "Billing") {
        event.preventDefault();
        showCheckout();
      }
    };
    window.addEventListener("keydown", shortcut);
    return () => window.removeEventListener("keydown", shortcut);
  });
  useEffect(() => {
    const Detector = (window as any).BarcodeDetector;
    if (window.motorlineNative || !Detector?.getSupportedFormats || !navigator.mediaDevices)
      return;
    Detector.getSupportedFormats()
      .then((formats: string[]) => setCameraScan(formats.length > 0))
      .catch(() => setCameraScan(false));
  }, []);
  useEffect(() => {
    if (!resumeCheckout.current || modal) return;
    resumeCheckout.current = false;
    showCheckout();
  });
  useEffect(() => {
    if (role && !allowedSections.includes(section))
      setSection(allowedSections[0] || "Settings");
  }, [role, section]);

  async function refresh(message?: string) {
    if (session) await synchronize(session);
    if (message) toast(message);
  }
  async function mutate(path: string, body: Json, message: string) {
    const payload = {
      ...body,
      transactionId: body.transactionId || crypto.randomUUID(),
    };
    let result;
    try {
      result = await api(path, payload);
    } catch (reason) {
      if (reason instanceof ApiError && reason.status < 500) throw reason;
      result = await api(path, payload);
    }
    await refresh(message);
    return result;
  }
  function form(
    title: string,
    fields: Field[],
    action: (data: Json) => Promise<void>,
    submit = "Save",
    expanded = false,
  ) {
    setError("");
    setModal({ title, fields, action, submit, expanded });
  }
  const partField = (): Field => ({
    name: "productId",
    label: "Part",
    options: options(products, (product) => `${product.sku} · ${product.name}`),
    required: true,
  });
  const binField = (name = "binId", label = "Bin", kind?: string): Field => ({
    name,
    label,
    options: options(
      kind ? bins.filter((bin) => bin.kind === kind) : bins,
      binName,
    ),
    required: true,
  });
  const quantityField = (
    name = "quantity",
    label = "Quantity",
    value = 1,
  ): Field => ({ name, label, type: "number", min: 1, value, required: true });
  const reasonField: Field = {
    name: "reason",
    label: "Reason",
    required: true,
  };
  async function approval(
    action: string,
    transactionId: string,
    reason: string,
  ) {
    const result = await api("/approvals", { action, transactionId, reason });
    return result.id;
  }
  function cartNeedsApprovalFor(value: Json) {
    return value.lines.some((line: Json) => {
      const product = products.find((item) => item.id === line.productId);
      return (
        product &&
        ["incompatible", "unverified"].includes(
          fitment(product, value.vehicle).status,
        ) &&
        !line.overrideReason
      );
    });
  }
  function available(productId: string, binId?: string) {
    const physical = stock
      .filter(
        (item) =>
          item.productId === productId &&
          (binId
            ? item.binId === binId
            : bins.some(
                (bin) => bin.id === item.binId && bin.kind === "sellable",
              )),
      )
      .reduce(
        (sum, item) =>
          sum + (item.available ?? item.quantity - (item.reserved || 0)),
        0,
      );
    const pending = (workspace?.pending || [])
      .flatMap((item) => item.transaction.lines)
      .filter(
        (item) =>
          item.productId === productId && (!binId || item.binId === binId),
      )
      .reduce((sum, item) => sum + item.qty, 0);
    const ownHold = (snapshot.holds || []).find(
      (hold: Json) => hold.id === cart?.holdId,
    );
    const reserved = (ownHold?.cart.lines || [])
      .filter(
        (line: Json) =>
          line.productId === productId && (!binId || line.binId === binId),
      )
      .reduce((sum: number, line: Json) => sum + line.qty, 0);
    return physical - pending + reserved;
  }
  function setLineQuantity(index: number, qty: number, quiet = false) {
    if (!cart) return false;
    const line = cart.lines[index];
    if (!line) return false;
    if (qty < 1) {
      updateCart({
        lines: cart.lines.filter((_: Json, i: number) => i !== index),
      });
      return true;
    }
    if (qty > 9999) return false;
    const product = products.find((item) => item.id === line.productId);
    if (
      line.binId &&
      product?.type !== "service" &&
      qty > available(line.productId, line.binId)
    ) {
      if (!quiet)
        toast(`Only ${available(line.productId, line.binId)} available in ${locationName(line.binId)}.`);
      return false;
    }
    updateCart({
      lines: cart.lines.map((item: Json, i: number) =>
        i === index ? { ...item, qty } : item,
      ),
    });
    return true;
  }
  /** Barcodes win over SKUs, which win over manufacturer and cross references. */
  function findByCode(code: string) {
    const key = normalize(code);
    if (!key) return [];
    const exact = (values: unknown[]) => values.some((value) => normalize(value) === key);
    const tiers = [
      (product: Json) => exact(product.barcodes || []),
      (product: Json) => exact([product.sku]),
      (product: Json) =>
        exact([
          product.partNumber,
          ...(product.oemReferences || []),
          ...(product.supplierReferences || []),
          ...(product.supersedes || []),
          ...(product.interchanges || []),
        ]),
    ];
    for (const tier of tiers) {
      const found = products.filter(tier);
      if (found.length) return found;
    }
    return [];
  }
  function handleScan(raw: string) {
    const code = raw.trim();
    if (!code) return;
    const bin = bins.find((item) => normalize(item.id) === normalize(code));
    const matches = findByCode(code);
    if (section !== "Billing" || !canSell) {
      // Outside the counter a scan looks the item up in the current list.
      setSearch(bin && !matches.length ? binName(bin) : code);
      if (!matches.length && !bin) toast(`No part or bin matches “${code}”.`);
      return;
    }
    if (!matches.length) {
      setSearch(code);
      toast(
        bin
          ? `${binName(bin)} is a bin label. Scan the part barcode to add it.`
          : `No part matches “${code}”. Check the code or add it to the part in Inventory.`,
      );
      return;
    }
    if (matches.length > 1) {
      setSearch(code);
      setCategory("All parts");
      toast(`${matches.length} parts share “${code}”. Choose the correct one below.`);
      return;
    }
    const product = matches[0];
    setSearch("");
    if (cart && !product.serialTracked) {
      // A repeat scan adds one more from the bin already confirmed for this sale.
      const indexes = cart.lines
        .map((line: Json, index: number) => (line.productId === product.id ? index : -1))
        .filter((index: number) => index >= 0);
      for (const index of indexes)
        if (setLineQuantity(index, cart.lines[index].qty + 1, true)) {
          toast(`${product.name} × ${cart.lines[index].qty + 1}`);
          return;
        }
      if (indexes.length && product.type !== "service") {
        const otherBins = bins.some(
          (item) =>
            item.kind === "sellable" &&
            available(product.id, item.id) > 0 &&
            !cart.lines.some(
              (line: Json) => line.productId === product.id && line.binId === item.id,
            ),
        );
        if (!otherBins) {
          toast(`No more ${product.name} available to sell.`);
          return;
        }
      }
    }
    addPart(product);
  }
  async function scanWithDevice() {
    try {
      if (window.motorlineNative?.platform === "android") {
        const code = await window.motorlineNative.scan();
        if (code) handleScan(code);
        return;
      }
      setError("");
      setModal({
        title: "Scan barcode",
        content: (
          <CameraScanner
            onCode={(code) => {
              setModal(null);
              setTimeout(() => handleScanRef.current(code), 0);
            }}
          />
        ),
      });
    } catch (reason) {
      fail(reason);
    }
  }
  function addPart(product: Json) {
    if (!cart) return;
    if (!canSell) {
      toast("Your role cannot create sales.");
      return;
    }
    const result = fitment(product, cart.vehicle);
    const service =
      product.type === "service" || product.category === "Services";
    const choices = bins.filter(
      (bin) => bin.kind === "sellable" && available(product.id, bin.id) > 0,
    );
    if (!service && !choices.length) {
      toast(`${product.name} is out of stock in every sellable bin.`);
      return;
    }
    const fields: Field[] = [
      quantityField("qty"),
      ...(service
        ? []
        : [
            {
              name: "binId",
              label: "Confirm the bin picked",
              options: options(
                choices,
                (bin) =>
                  `${binName(bin)} · ${available(product.id, bin.id)} available`,
              ),
              value: choices[0]?.id,
              required: true,
            },
          ]),
    ];
    if (product.serialTracked)
      fields.push({
        name: "serials",
        label: "Serial numbers, comma separated",
        required: true,
      });
    if (["incompatible", "unverified"].includes(result.status))
      fields.push({
        name: "overrideReason",
        label: `${titleCase(result.status)} fitment — override reason`,
        required: true,
        help: result.missing.length
          ? `Complete ${result.missing.join(", ")} in vehicle selection to verify this match.`
          : undefined,
      });
    if (!manager && ["incompatible", "unverified"].includes(result.status))
      fields.push({
        name: "approvalId",
        label: "Manager approval ID",
        required: true,
        help: `Ask a manager to approve fitment for transaction ${cart.transactionId}.`,
      });
    form(
      `Add ${product.name}`,
      fields,
      async (data) => {
        const qty = Number(data.qty);
        if (!Number.isInteger(qty) || qty < 1 || qty > 9999)
          throw new Error("Enter a whole-number quantity from 1 to 9999. If a barcode was scanned into this field, close the dialog and scan again.");
        const existing = cart.lines.find(
          (line: Json) =>
            line.productId === product.id &&
            (line.binId || null) === (data.binId || null),
        );
        if (product.serialTracked && list(data.serials).length !== qty)
          throw new Error("Enter one serial number for each unit.");
        if (
          data.binId &&
          qty + (existing?.qty || 0) > available(product.id, data.binId)
        )
          throw new Error("Quantity exceeds this bin’s available snapshot.");
        let approvalId = data.approvalId || cart.approvalId;
        if (data.overrideReason && manager)
          approvalId = await approval(
            "fitment",
            cart.transactionId,
            data.overrideReason,
          );
        const line = {
          productId: product.id,
          qty: qty + (existing?.qty || 0),
          binId: data.binId || null,
          serials: [...(existing?.serials || []), ...list(data.serials)],
          overrideReason: data.overrideReason || existing?.overrideReason || "",
        };
        updateCart({
          approvalId,
          lines: [
            ...cart.lines.filter((item: Json) => item !== existing),
            line,
          ],
        });
      },
      "Add to sale",
    );
  }
  function chooseVehicle() {
    const current = cart?.vehicle || {};
    form(
      "Vehicle fitment",
      [
        {
          name: "preset",
          label: "Saved vehicle",
          options: options(
            snapshot.vehicles || [],
            (vehicle) =>
              `${vehicle.year} ${vehicle.make} ${vehicle.model} ${vehicle.engine || ""}`,
          ),
        },
        ...[
          "make",
          "model",
          "year",
          "engine",
          "fuel",
          "trim",
          "drivetrain",
          "market",
        ].map((name) => ({
          name,
          label: name[0].toUpperCase() + name.slice(1),
          type: name === "year" ? "number" : "text",
          value: current[name] || "",
          advanced: !["make", "model", "year"].includes(name),
          help:
            name === "engine"
              ? "Needed only when a part fits one engine or fuel."
              : undefined,
        })),
      ],
      async (data) => {
        const vehicle = data.preset
          ? snapshot.vehicles.find((item: Json) => item.id === data.preset)
          : data.make && data.model
            ? { ...data, year: Number(data.year) }
            : null;
        const incompatible = cart?.lines.filter((line: Json) =>
          ["unverified", "incompatible"].includes(
            fitment(
              products.find((product) => product.id === line.productId)!,
              vehicle,
            ).status,
          ),
        );
        updateCart({
          vehicle,
          approvalId: undefined,
          lines: cart?.lines.map((line: Json) => ({
            ...line,
            overrideReason: "",
          })),
        });
        if (incompatible?.length)
          toast(
            "Vehicle changed. Review the flagged cart lines and obtain approval before checkout.",
          );
      },
      "Use vehicle",
      ["engine", "fuel", "trim", "drivetrain", "market"].some((name) => current[name]),
    );
  }
  function approveCart() {
    form(
      "Approve fitment",
      [
        reasonField,
        ...(!manager
          ? [
              {
                name: "approvalId",
                label: "Manager approval ID",
                required: true,
              },
            ]
          : []),
      ],
      async (data) => {
        const approvalId = manager
          ? await approval("fitment", cart!.transactionId, data.reason)
          : data.approvalId;
        updateCart({
          approvalId,
          lines: cart!.lines.map((line: Json) => ({
            ...line,
            overrideReason: data.reason,
          })),
        });
      },
      "Record approval",
    );
  }

  async function checkout(data: Json) {
    if (!cart || !workspace || !session) return;
    const bill = quote(
      cart,
      products,
      snapshot.settings?.roundingIncrement || 1,
      snapshot.settings?.taxMode || "exclusive",
    );
    const activeShift = (snapshot.shifts || []).find(
      (shift: Json) => !shift.closedAt && shift.userId === session.user.id,
    );
    const transaction: Json = {
      ...cart,
      placeOfSupply: String(data.placeOfSupply || "").trim(),
      shiftId: activeShift?.id,
      catalogRevision: snapshot.catalogRevision,
      occurredAt: new Date().toISOString(),
      tenders: [
        {
          type: data.tender,
          amount: Math.round(Number(data.amount) * 100),
          confirmed: data.tender === "Cash" || data.confirmed === "yes",
          reference: data.reference || "",
        },
        ...(Number(data.secondAmount) > 0
          ? [
              {
                type: data.secondTender,
                amount: Math.round(Number(data.secondAmount) * 100),
                confirmed:
                  data.secondTender === "Cash" || data.confirmed === "yes",
                reference: data.reference || "",
              },
            ]
          : []),
      ],
    };
    if (
      transaction.tenders.reduce(
        (sum: number, item: Json) => sum + item.amount,
        0,
      ) < bill.total
    )
      throw new Error("Payment must cover the total.");
    const paid = transaction.tenders.reduce(
      (sum: number, tender: Json) => sum + tender.amount,
      0,
    );
    const cash = transaction.tenders
      .filter((tender: Json) => tender.type === "Cash")
      .reduce((sum: number, tender: Json) => sum + tender.amount, 0);
    if (paid - bill.total > cash)
      throw new Error("Change must be paid from cash received.");
    const awaitingPayment = transaction.tenders.some(
      (tender: Json) => tender.type !== "Cash" && !tender.confirmed,
    );
    const receiptDetails: Json = {
      currency:snapshot.settings?.currency, business:snapshot.settings?.business,
      branch:snapshot.branch, taxDisplayName:snapshot.settings?.taxDisplayName,
      taxScheme:snapshot.settings?.taxScheme || "general", localTaxName:snapshot.settings?.localTaxName || "SGST",
      receiptFooter:snapshot.settings?.receiptFooter, placeOfSupply:transaction.placeOfSupply,
      customer:(snapshot.customers || []).find((customer:Json)=>customer.id === cart.customerId),
    };
    if (receiptDetails.taxScheme === "india-gst") {
      const business = receiptDetails.business || {};
      if (!business.legalName || !business.address || !/^[0-9]{2}$/.test(business.stateCode || "") || !/^[0-9]{2}[A-Z0-9]{13}$/.test(business.taxRegistrationId || ""))
        throw new Error("Complete the registered business GST details in Settings before checkout.");
      if (!/^[0-9]{2}$/.test(transaction.placeOfSupply)) throw new Error("Enter the two-digit place-of-supply state code.");
      const totals: Record<string,number> = {};
      for (const line of bill.lines) {
        if (!/^\d{4,8}$/.test(line.product.hsnSac || "")) throw new Error("Each GST line needs a valid HSN / SAC code.");
        if (line.core) throw new Error("GST treatment of refundable core deposits must be configured separately before this sale.");
        const sameState=transaction.placeOfSupply === business.stateCode;
        const central=Math.floor((line.tax+1)/2);
        line.taxComponents=sameState ? [{name:"CGST",rate:line.product.taxRate/2,amount:central},{name:receiptDetails.localTaxName,rate:line.product.taxRate/2,amount:line.tax-central}] : [{name:"IGST",rate:line.product.taxRate,amount:line.tax}];
        for (const component of line.taxComponents) totals[component.name]=(totals[component.name] || 0)+component.amount;
      }
      receiptDetails.taxComponents=Object.entries(totals).map(([name,amount])=>({name,amount}));
    }
    if (transaction.tenders.some((tender:Json) => !(snapshot.settings?.tenderTypes || ["Cash","Card","UPI"]).includes(tender.type)))
      throw new Error("This payment type is disabled in register settings.");
    if (transaction.tenders.some((tender:Json) => tender.type !== "Cash" && tender.confirmed && !tender.reference.trim()))
      throw new Error("Enter the confirmed payment reference for card or UPI payments.");
    const expires = new Date(session.expiresAt).getTime();
    if (!online) {
      if (!["owner", "manager", "cashier"].includes(session.user.role))
        throw new Error("Your role does not permit offline checkout.");
      if (!activeShift)
        throw new Error("An open shift is required for offline checkout.");
      if (!workspace.device || !workspace.device.offlineAllowed)
        throw new Error(
          "This counter needs online enrollment with offline checkout enabled.",
        );
      if (Date.now() > expires)
        throw new Error(
          "Your session has expired. Reconnect and sign in before checkout.",
        );
      if (Date.now() > new Date(workspace.device.offlineUntil).getTime())
        throw new Error(
          "The counter offline authorization has expired. Reconnect to renew it.",
        );
      if (
        transaction.tenders.some(
          (item: Json) =>
            !(workspace.device?.tenders || ["Cash"]).includes(item.type),
        )
      )
        throw new Error("This tender is not authorized offline.");
      if (
        cart.lines.some((line: Json) =>
          ["unverified", "incompatible"].includes(
            fitment(
              products.find((product) => product.id === line.productId)!,
              cart.vehicle,
            ).status,
          ),
        )
      )
        throw new Error("Fitment approvals require a server connection.");
    }
    await locked(deviceKey(session), async () => {
      const latest =
        (await readLocal<Workspace>(scopeKey(session))) || workspace;
      let pendingTransaction = latest.pending.find(
        (item) => item.transaction.transactionId === transaction.transactionId,
      );
      if (!pendingTransaction) {
        const offline = !online;
        const enrollment = await readLocal<Json>(deviceKey(session));
        const device = enrollment?.device || latest.device;
        const invoiceNumber = enrollment?.nextInvoice ?? latest.nextInvoice;
        if (
          offline &&
          invoiceNumber > (device?.rangeEnd ?? device?.invoiceRangeEnd ?? 0)
        )
          throw new Error(
            "This device invoice range is exhausted. Reconnect to renew enrollment.",
          );
        if (offline)
          await writeLocal(deviceKey(session), {
            device,
            nextInvoice: invoiceNumber + 1,
          });
        pendingTransaction = {
          transaction: {
            ...transaction,
            offline,
            ...(offline ? { deviceId: device!.id, invoiceNumber } : {}),
          },
          status: awaitingPayment ? "awaiting-payment" : "pending",
          localQuote: {...bill, ...receiptDetails},
          createdAt: new Date().toISOString(),
        };
        // Persist the stable transaction before sending. Retrying never generates a new sale ID.
        const next = {
          ...latest,
          pending: [...latest.pending, pendingTransaction],
          nextInvoice: offline ? invoiceNumber + 1 : invoiceNumber,
          cart: emptyCart(),
        };
        await writeLocal(scopeKey(session), next);
        setWorkspace(next);
      }
      if (awaitingPayment) {
        toast(
          "Payment saved as pending. Confirm the provider reference in Reconciliation.",
        );
      } else if (online) {
        try {
          const invoice = await api(
            "/invoices",
            pendingTransaction.transaction,
          );
          const latestState = (await readLocal<Workspace>(scopeKey(session)))!;
          await writeLocal(scopeKey(session), {
            ...latestState,
            pending: latestState.pending.filter(
              (item) =>
                item.transaction.transactionId !== transaction.transactionId,
            ),
            cart: emptyCart(),
          });
          setReceipt(invoice);
        } catch (reason) {
          if (reason instanceof ApiError && reason.status < 500) {
            const latestState = (await readLocal<Workspace>(
              scopeKey(session),
            ))!;
            await writeLocal(scopeKey(session), {
              ...latestState,
              pending: latestState.pending.filter(
                (item) =>
                  item.transaction.transactionId !== transaction.transactionId,
              ),
            });
            setWorkspace({
              ...latestState,
              pending: latestState.pending.filter(
                (item) =>
                  item.transaction.transactionId !== transaction.transactionId,
              ),
            });
            throw reason;
          }
          setOnline(false);
          toast(
            "Server response pending. The transaction is saved and will retry with the same ID.",
          );
        }
      } else {
        setReceipt({
          ...pendingTransaction.localQuote,
          ...transaction,
          lines:pendingTransaction.localQuote.lines,
          change: paid - bill.total,
          number: `Pending ${pendingTransaction.transaction.invoiceNumber}`,
          status: "Pending synchronization",
        });
      }
    });
    setCart(emptyCart());
    await refresh();
  }
  function showCheckout() {
    if (!cart?.lines.length || !canSell) return;
    if (cartNeedsApprovalFor(cart)) {
      setError("Record the fitment approval for the flagged lines before checkout.");
      return;
    }
    let bill;
    try {
      bill = quote(
        cart,
        products,
        snapshot.settings?.roundingIncrement || 1,
        snapshot.settings?.taxMode || "exclusive",
      );
    } catch (reason) {
      fail(reason);
      return;
    }
    const shifts = (snapshot.shifts || []).filter(
      (shift: Json) =>
        !shift.closedAt && (!shift.userId || shift.userId === session?.user.id),
    );
    if (!shifts.length) {
      openShift(true);
      return;
    }
    if (!cart.shiftId && shifts.length) updateCart({ shiftId: shifts[0].id });
    const gst = snapshot.settings?.taxScheme === "india-gst";
    setError("");
    setModal({
      title: `Checkout · ${money(bill.total)}`,
      content: (
        <CheckoutFields
          total={bill.total}
          tenders={tenderTypes}
          money={money}
          gst={gst}
          placeOfSupply={
            (snapshot.customers || []).find(
              (customer: Json) => customer.id === cart.customerId,
            )?.stateCode ||
            snapshot.settings?.business?.stateCode ||
            ""
          }
        />
      ),
      action: checkout,
      submit: online ? "Complete sale" : "Save offline sale",
    });
  }
  async function holdSale() {
    if (!cart?.lines.length) return;
    await mutate(
      "/holds",
      { id: cart.holdId, cart },
      "Sale parked. Stock reserved.",
    );
    setCart(emptyCart());
  }

  function editBusiness() {
    const business = snapshot.settings?.business || {};
    form("Business and receipt details", [
      {name:"legalName", label:"Legal business name", value:business.legalName, required:true},
      {name:"tradingName", label:"Trading name", value:business.tradingName},
      {name:"address", label:"Registered address", type:"textarea", value:business.address, required:true},
      {name:"taxRegistrationId", label:"Tax registration / GSTIN", value:business.taxRegistrationId},
      {name:"stateCode", label:"Business state code", value:business.stateCode},
      {name:"phone", label:"Business phone", type:"tel", value:business.phone},
      {name:"email", label:"Business email", type:"email", value:business.email},
      {name:"branchName", label:"Current branch name", value:snapshot.branch?.name, required:true},
      {name:"branchAddress", label:"Current branch address", type:"textarea", value:snapshot.branch?.address},
      {name:"branchStateCode", label:"Current branch state code", value:snapshot.branch?.stateCode},
      {name:"receiptFooter", label:"Receipt footer", type:"textarea", value:snapshot.settings?.receiptFooter},
    ], async data => {
      const {branchName, branchAddress, branchStateCode, receiptFooter, ...business} = data;
      await mutate("/settings", {business, branchName, branchAddress, branchStateCode, receiptFooter}, "Business details saved. Issued invoices retain their original details.");
    });
  }
  function editRegisterSettings() {
    const settings = snapshot.settings;
    const symbol = money(0).replace(/[\d.,\s]/g, "") || settings.currency;
    const rounding = [
      { value: "1", label: "No rounding" },
      { value: "50", label: `Nearest ${symbol}0.50` },
      { value: "100", label: `Nearest ${symbol}1` },
      { value: "1000", label: `Nearest ${symbol}10` },
    ];
    if (!rounding.some((option) => Number(option.value) === settings.roundingIncrement))
      rounding.push({ value: String(settings.roundingIncrement), label: `${money(settings.roundingIncrement)} steps` });
    form("Register settings", [
      {name:"taxScheme", label:"Tax", options:[{value:"general",label:"General tax"},{value:"india-gst",label:"India GST (domestic sales)"}], value:settings.taxScheme || "general", required:true, help:"GST needs the business GSTIN and state, and an HSN/SAC on each part."},
      {name:"taxMode", label:"Catalog prices", options:[{value:"exclusive",label:"Exclude tax (tax added at billing)"},{value:"inclusive",label:"Include tax (MRP style)"}], value:settings.taxMode || "exclusive", required:true},
      {name:"taxRates", label:"Tax rates offered (%)", value:(settings.taxRates || []).map((rate:number)=>rate/100).join(", "), required:true, help:"Separate with commas, for example 0, 5, 12, 18, 28."},
      {name:"tenderTypes", label:"Payment types accepted", type:"checks", options:["Cash","Card","UPI"].map(value=>({value,label:value})), value:settings.tenderTypes || ["Cash","Card","UPI"], help:"Card and UPI need the provider's payment reference."},
      {name:"roundingIncrement", label:"Round bill totals to", options:rounding, value:String(settings.roundingIncrement || 1), required:true},
      {name:"cashierDiscountLimit", label:"Cashier can discount up to", type:"number", min:0, step:"0.01", value:(settings.cashierDiscountLimit || 0)/100, required:true, help:"Larger discounts need a manager approval."},
      {name:"invoicePrefix", label:"Invoice number prefix", value:settings.invoicePrefix, required:true},
      {name:"creditNotePrefix", label:"Credit note prefix", value:settings.creditNotePrefix || "CR", required:true, advanced:true},
      {name:"nextInvoice", label:"Next invoice number", type:"number", min:1, value:settings.nextInvoice, advanced:true, help:"Can only move forward."},
      {name:"taxDisplayName", label:"Tax label on receipts", value:settings.taxDisplayName || "Tax", advanced:true},
      {name:"localTaxName", label:"Local GST component", options:[{value:"SGST",label:"SGST (states)"},{value:"UTGST",label:"UTGST (union territories)"}], value:settings.localTaxName || "SGST", advanced:true},
      {name:"currency", label:"Currency code", value:settings.currency, advanced:true, help:"Locked once sales exist."},
      {name:"sessionHours", label:"Sign staff out after (hours)", type:"number", min:1, value:settings.sessionHours, advanced:true},
      ...(features.offline ? [
        {name:"offlineHours", label:"Maximum offline selling (hours)", type:"number", min:0, value:settings.offlineHours, advanced:true},
        {name:"offlineTenders", label:"Allowed while offline", type:"checks", options:[{value:"Cash",label:"Cash"}], value:settings.offlineTenders || [], advanced:true},
      ] as Field[] : []),
    ], async data => {
      if (!(data.tenderTypes || []).length) throw new Error("Choose at least one payment type.");
      const number = (key: string) => (String(data[key] ?? "").trim() === "" ? undefined : Number(data[key]));
      const body: Json = {
        taxScheme: data.taxScheme,
        taxMode: data.taxMode,
        taxRates: list(data.taxRates).map(rate=>Math.round(Number(rate)*100)),
        tenderTypes: data.tenderTypes,
        roundingIncrement: Number(data.roundingIncrement),
        cashierDiscountLimit: Math.round(Number(data.cashierDiscountLimit || 0) * 100),
        invoicePrefix: data.invoicePrefix,
        creditNotePrefix: data.creditNotePrefix,
        taxDisplayName: String(data.taxDisplayName || "").trim() || "Tax",
        localTaxName: data.localTaxName || "SGST",
        currency: data.currency || settings.currency,
        nextInvoice: number("nextInvoice"),
        sessionHours: number("sessionHours"),
      };
      if (features.offline) {
        body.offlineHours = number("offlineHours");
        body.offlineTenders = data.offlineTenders || [];
      }
      await mutate("/settings", body, "Register settings saved. Check catalog prices if you changed how tax is included.");
    });
  }
  function editUser(user: Json = {}) {
    form(user.id ? "Edit user" : "Create user", [
      {name:"name",label:"Name",value:user.name,required:true},
      {name:"email",label:"Email",type:"email",value:user.email,required:true},
      {name:"password",label:user.id ? "New password (leave blank to retain)" : "Password, at least 12 characters",type:"password",required:!user.id},
      {name:"role",label:"Role",options:["owner","manager","cashier","inventory"].map(value=>({value,label:value})),value:user.role,required:true},
      {name:"branchIds",label:"Authorized branch codes, comma separated",value:(user.branchIds || [session!.branchId]).join(", "),required:true},
      {name:"active",label:"Account status",options:[{value:"true",label:"Active"},{value:"false",label:"Disabled"}],value:String(user.active !== false),required:true},
    ], async data => {
      await api("/users", {...user,...data,branchIds:list(data.branchIds),active:data.active === "true"});
      if (user.id === session?.user.id) {
        await writeLocal("active-session",null); setSession(null);setWorkspace(null);setCart(null);
        toast("Your access was updated. Sign in again with your current credentials.");
      } else { await refresh();toast("User access saved. Existing sessions must sign in again."); }
    });
  }
  function editBranch(branch: Json = {}) {
    form(branch.id ? "Edit branch" : "Add branch", [
      {name:"id",label:"Branch code",value:branch.id,required:true,help:branch.id ? "The existing branch code is retained." : "Use lowercase letters, numbers and hyphens."},
      {name:"name",label:"Branch name",value:branch.name,required:true},
      {name:"address",label:"Branch address",type:"textarea",value:branch.address},
      {name:"stateCode",label:"Branch state code",value:branch.stateCode},
    ],async data => {
      await mutate("/branches", {...data, ...(branch.id ? {id:branch.id} : {})}, "Branch saved. Assign staff access before using this branch.");
    });
  }
  function commonTaxRate() {
    const counts = new Map<number, number>();
    for (const item of products)
      if (item.type !== "service") counts.set(item.taxRate, (counts.get(item.taxRate) || 0) + 1);
    const used = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
    return used ?? snapshot.settings?.taxRates?.[0] ?? 0;
  }
  function editProduct(product: Json = {}) {
    const gst = snapshot.settings?.taxScheme === "india-gst";
    const text = (name: string, label: string, extra: Partial<Field> = {}): Field => ({
      name,
      label,
      value: product[name] ?? "",
      ...extra,
    });
    const listField = (name: string, label: string, advanced = true): Field => ({
      name,
      label,
      value: (product[name] || []).join(", "),
      help: "Separate several with commas.",
      advanced,
    });
    const price = (name: string, label: string, extra: Partial<Field> = {}): Field => ({
      name,
      label,
      type: "number",
      min: 0,
      step: "0.01",
      value: product[name] !== undefined ? product[name] / 100 : "",
      ...extra,
    });
    const fields: Field[] = [
      text("name", "Part name", { required: true }),
      text("sku", "SKU / item code", { required: true }),
      text("brand", "Brand", { required: true }),
      text("category", "Category", {
        required: true,
        suggestions: [...new Set(products.map((item) => item.category).filter(Boolean))],
      }),
      text("partNumber", "Manufacturer part number"),
      listField("barcodes", "Barcode", false),
      {
        name: "generateBarcode",
        label: "If no barcode",
        options: [
          { value: "true", label: "Create an in-store barcode" },
          { value: "false", label: "None (labels print the SKU)" },
        ],
        value: product.barcodes?.length ? "false" : "true",
      },
      price("retailPrice", "Retail price", { required: true }),
      price("wholesalePrice", "Wholesale price", { help: "Leave blank to use the retail price." }),
      price("cost", "Purchase cost", { required: true }),
      {
        name: "taxRate",
        label: "Tax rate (%)",
        type: "number",
        value: (product.taxRate ?? commonTaxRate()) / 100,
        step: "0.01",
        min: 0,
        required: true,
      },
      { name: "hsnSac", label: "HSN / SAC", value: product.hsnSac || "", advanced: !gst, required: gst },
      {
        name: "reorderLevel",
        label: "Reorder when stock falls to",
        type: "number",
        min: 0,
        value: product.reorderLevel ?? 0,
      },
      {
        name: "universal",
        label: "Fits",
        options: [
          { value: "true", label: "All vehicles (universal)" },
          { value: "false", label: "Specific vehicles only" },
        ],
        value: String(product.universal ?? !features.fitment),
        advanced: !features.fitment,
      },
      text("description", "Description", { advanced: true }),
      text("unit", "Unit", { value: product.unit || "Each", advanced: true }),
      {
        name: "supplierId",
        label: "Usual supplier",
        options: options(snapshot.suppliers || []),
        value: product.supplierId,
        advanced: true,
      },
      listField("oemReferences", "OEM references"),
      listField("supplierReferences", "Supplier part references"),
      listField("supersedes", "Replaces part numbers"),
      listField("interchanges", "Interchange references"),
      listField("alternatives", "Alternative SKU IDs"),
      price("coreCharge", "Refundable core deposit", { advanced: true, value: (product.coreCharge || 0) / 100 }),
      text("taxCategory", "Tax category", { value: product.taxCategory || "Standard", advanced: true }),
      {
        name: "packSize",
        label: "Pack size",
        type: "number",
        min: 1,
        value: product.packSize || 1,
        advanced: true,
      },
      {
        name: "serialTracked",
        label: "Serial numbers",
        options: [
          { value: "false", label: "Not tracked" },
          { value: "true", label: "Record a serial for every unit" },
        ],
        value: String(product.serialTracked || false),
        advanced: true,
      },
    ];
    form(product.id ? `Edit ${product.name}` : "Add part", fields, async (data) => {
      const values: Json = {
        ...product,
        ...data,
        universal: data.universal === "true",
        serialTracked: data.serialTracked === "true",
        packSize: Number(data.packSize) || 1,
        reorderLevel: Number(data.reorderLevel) || 0,
        taxRate: Math.round(Number(data.taxRate) * 100),
        unit: String(data.unit || "").trim() || "Each",
        taxCategory: String(data.taxCategory || "").trim() || "Standard",
      };
      if (String(data.wholesalePrice ?? "").trim() === "") data.wholesalePrice = data.retailPrice;
      for (const key of ["cost", "retailPrice", "wholesalePrice", "coreCharge"])
        values[key] = Math.round((Number(data[key]) || 0) * 100);
      for (const key of [
        "barcodes",
        "oemReferences",
        "supplierReferences",
        "alternatives",
        "supersedes",
        "interchanges",
      ])
        values[key] = list(data[key]);
      const generate = values.generateBarcode === "true";
      delete values.generateBarcode;
      values.barcodes = [...new Set<string>(values.barcodes)];
      const taken = new Set<string>(
        products
          .filter((item) => item.id !== product.id)
          .flatMap((item) => item.barcodes || []),
      );
      const duplicate = values.barcodes.find((code: string) => taken.has(code));
      if (duplicate) {
        const owner = products.find((item) => item.barcodes?.includes(duplicate));
        throw new Error(`Barcode ${duplicate} already belongs to ${owner?.name || "another part"}.`);
      }
      const badCheck = values.barcodes.find(
        (code: string) => /^\d{13}$/.test(code) && !gs1Valid(code),
      );
      if (badCheck)
        throw new Error(`${badCheck} looks like an EAN-13 but its check digit is wrong. Re-scan it from the packaging.`);
      let created = "";
      if (generate && !values.barcodes.length) {
        created = inStoreBarcode(taken);
        values.barcodes = [created];
      }
      await mutate(
        "/products",
        values,
        created ? `Part saved with in-store barcode ${created}.` : "Part saved.",
      );
    });
  }
  function editLocation(bin: Json = {}) {
    form(
      bin.id ? "Rename location" : "Add storage location",
      [
        ...["area", "rack", "shelf", "bin"].map((name) => ({
          name,
          label: name[0].toUpperCase() + name.slice(1),
          value: bin[name] || "",
          required: true,
        })),
        {
          name: "kind",
          label: "Stock condition",
          options: ["sellable", "damaged", "warranty"].map((value) => ({
            value,
            label: value,
          })),
          value: bin.kind || "sellable",
        },
      ],
      async (data) => {
        await mutate("/locations", { ...bin, ...data }, "Location saved.");
      },
    );
  }
  function stockOperation(kind: string) {
    const transactionId = crypto.randomUUID();
    const fields = [
      partField(),
      ...(kind === "move"
        ? [binField("fromBinId", "From"), binField("toBinId", "To")]
        : [binField()]),
      {
        ...quantityField(
          kind === "count" ? "counted" : "quantity",
          kind === "count" ? "Counted quantity" : "Quantity change",
        ),
        min: kind === "adjust" ? undefined : 0,
      },
      { name: "serials", label: "Serial numbers (serial-tracked parts only)", help: "Separate with commas.", advanced: true },
      reasonField,
      ...(!manager && kind !== "move"
        ? [
            {
              name: "approvalId",
              label: "Manager approval ID",
              required: true,
              help: `Approval transaction ${transactionId}`,
            },
          ]
        : []),
    ];
    form(
      { move: "Move stock", adjust: "Adjust stock", count: "Stock count" }[
        kind
      ]!,
      fields,
      async (data) => {
        await mutate(
          `/inventory/${kind}`,
          {
            ...data,
            transactionId,
            serials: list(data.serials),
            quantity: Number(data.quantity),
            counted: Number(data.counted),
          },
          "Stock ledger updated.",
        );
      },
    );
  }
  function createPurchase() {
    form(
      "New purchase order",
      [
        {
          name: "supplierId",
          label: "Supplier",
          options: options(snapshot.suppliers || []),
          required: true,
        },
        partField(),
        quantityField(),
        {
          name: "cost",
          label: "Unit cost",
          type: "number",
          min: 0,
          step: "0.01",
          required: true,
        },
      ],
      async (data) => {
        await mutate(
          "/purchase-orders",
          {
            supplierId: data.supplierId,
            lines: [
              {
                productId: data.productId,
                quantity: Number(data.quantity),
                cost: Math.round(Number(data.cost) * 100),
              },
            ],
          },
          "Purchase order created.",
        );
      },
    );
  }
  function receivePurchase(order: Json) {
    form(
      `Receive ${order.number || order.id}`,
      [
        {
          name: "productId",
          label: "Part",
          options: (order.lines || [])
            .filter((line: Json) => (line.received || 0) < line.quantity)
            .map((line: Json) => ({
              value: line.productId,
              label: `${productName(line.productId)} · ${line.quantity - (line.received || 0)} of ${line.quantity} outstanding`,
            })),
          value:
            (order.lines || []).filter((line: Json) => (line.received || 0) < line.quantity)
              .length === 1
              ? order.lines.find((line: Json) => (line.received || 0) < line.quantity).productId
              : undefined,
          required: true,
        },
        quantityField(),
        binField("binId", "Put away into bin", "sellable"),
        {
          advanced: true,
          name: "landedCost",
          label: "Additional landed cost for this receipt",
          type: "number",
          min: 0,
          step: "0.01",
          value: 0,
        },
        { name: "serials", label: "Serial numbers (serial-tracked parts only)", help: "Separate with commas.", advanced: true },
      ],
      async (data) => {
        await mutate(
          `/purchase-orders/${order.id}/receive`,
          {
            transactionId: crypto.randomUUID(),
            landedCost: Math.round(Number(data.landedCost) * 100),
            lines: [
              {
                productId: data.productId,
                quantity: Number(data.quantity),
                binId: data.binId,
                serials: list(data.serials),
              },
            ],
          },
          "Goods received into bin.",
        );
      },
      "Receive stock",
    );
  }
  function addContact(kind: string, contact: Json = {}, onSaved?: (saved: Json) => void) {
    const gst = snapshot.settings?.taxScheme === "india-gst";
    const extra = !gst;
    form(
      `${contact.id ? "Edit" : "Add"} ${kind === "customers" ? "customer" : "supplier"}`,
      [
        { name: "name", label: "Name", value: contact.name, required: true },
        { name: "phone", label: "Phone", type: "tel", value: contact.phone },
        { name: "email", label: "Email", type: "email", value: contact.email, advanced: true },
        { name: "address", label: "Address", type: "textarea", value: contact.address, advanced: extra },
        { name: "taxRegistrationId", label: "GSTIN / tax registration", value: contact.taxRegistrationId, advanced: extra },
        { name: "stateCode", label: "State code", value: contact.stateCode, advanced: extra, help: gst ? "Two digits, for example 27 for Maharashtra." : undefined },
      ],
      async (data) => {
        const saved = await mutate(`/${kind}`, {...contact, ...data}, `${kind === "customers" ? "Customer" : "Supplier"} saved.`);
        onSaved?.(saved);
      },
      "Save",
      !!(contact.email || contact.address || contact.taxRegistrationId || contact.stateCode),
    );
  }
  function editFitment(productId?: string) {
    form(
      "Add fitment rule",
      [
        { ...partField(), value: productId },
        ...[
          "make",
          "model",
          "engine",
          "fuel",
          "trim",
          "drivetrain",
          "market",
        ].map((name) => ({
          name,
          label: name[0].toUpperCase() + name.slice(1),
          required: ["make", "model"].includes(name),
          advanced: !["make", "model"].includes(name),
        })),
        {
          name: "yearFrom",
          label: "First model year",
          type: "number",
          value: 2020,
          required: true,
        },
        {
          name: "yearTo",
          label: "Last model year",
          type: "number",
          value: 2026,
          required: true,
        },
        {
          advanced: true,
          name: "exclusions",
          label: "Excluded vehicle configuration",
          help: "Example engine=2.0L,fuel=Diesel. These qualifiers must all match to exclude a vehicle.",
        },
        { name: "source", label: "Fitment data source", required: true },
        {
          name: "effectiveFrom",
          label: "Effective from",
          type: "date",
          value: new Date().toISOString().slice(0, 10),
          advanced: true,
        },
        { name: "effectiveTo", label: "Effective until", type: "date", advanced: true },
      ],
      async (data) => {
        const exclusion: Json = {};
        for (const pair of list(data.exclusions)) {
          const [key, value] = pair.split("=");
          if (
            !["engine", "fuel", "trim", "drivetrain", "market"].includes(key) ||
            !value
          )
            throw new Error("Use qualifier=value for exclusions.");
          exclusion[key] = value;
        }
        await mutate(
          "/fitments",
          {
            ...data,
            yearFrom: Number(data.yearFrom),
            yearTo: Number(data.yearTo),
            exclusions: Object.keys(exclusion).length ? [exclusion] : [],
            effectiveFrom: data.effectiveFrom || new Date().toISOString().slice(0, 10),
            effectiveTo: data.effectiveTo || null,
          },
          "Fitment rule added.",
        );
      },
    );
  }
  function csvImport() {
    form(
      "Preview fitment CSV",
      [
        {
          name: "csv",
          label: "CSV data",
          type: "textarea",
          required: true,
          value: "productId,make,model,yearFrom,yearTo,engine,fuel,source\n",
        },
      ],
      async (data) => {
        const preview = await api("/fitments/import/preview", data);
        setTimeout(
          () =>
            setModal({
              title: "Fitment import preview",
              content: (
                <div>
                  <pre className="preview-json">
                    {JSON.stringify(preview, null, 2)}
                  </pre>
                  <p>Review row errors before importing.</p>
                </div>
              ),
              fields: [
                {
                  name: "duplicateHandling",
                  label: "Duplicates",
                  options: [
                    { value: "skip", label: "Skip existing rules" },
                    { value: "replace", label: "Replace existing rules" },
                  ],
                  value: "skip",
                },
              ],
              submit: "Import valid data",
              action: async (values) => {
                await mutate(
                  "/fitments/import",
                  { ...data, ...values },
                  "Fitments imported.",
                );
              },
            }),
          0,
        );
      },
      "Validate and preview",
    );
  }
  function returnInvoice(invoice: Json) {
    const transactionId = crypto.randomUUID();
    const returnable = (invoice.lines || [])
      .map((line: Json) => ({
        line,
        remaining: line.qty - returnedQuantity(invoice, line.id),
      }))
      .filter((entry: Json) => entry.remaining > 0);
    if (!returnable.length) {
      toast("Every line on this invoice has already been returned.");
      return;
    }
    form(
      `Return from ${invoice.number}`,
      [
        {
          name: "lineId",
          label: "Original invoice line",
          options: returnable.map(({ line, remaining }: Json) => ({
            value: line.id,
            label: `${line.name || line.product?.name || productName(line.productId)} · ${remaining} of ${line.qty} returnable`,
          })),
          value: returnable.length === 1 ? returnable[0].line.id : undefined,
          required: true,
        },
        quantityField(),
        {
          name: "condition",
          label: "Returned condition",
          options: ["sellable", "damaged", "warranty"].map((value) => ({
            value,
            label: titleCase(value),
          })),
          value: "sellable",
          required: true,
          help: "The destination bin must have the same condition.",
        },
        {
          name: "binId",
          label: "Return destination bin",
          options: options(bins, (bin) => `${binName(bin)} · ${bin.kind}`),
          value: bins.find((bin) => bin.kind === "sellable")?.id,
          help: "Not needed for services.",
        },
        reasonField,
        {
          name: "refundType",
          label: "Refund method",
          options: tenderTypes.map((value) => ({
            value,
            label: value,
          })),
          value: invoice.tenders?.[0]?.type || "Cash",
          required: true,
        },
        { name: "serials", label: "Returned serial numbers (serial-tracked parts only)", help: "Separate with commas.", advanced: true },
        ...(!manager
          ? [
              {
                name: "approvalId",
                label: "Manager approval ID",
                required: true,
                help: `Approval transaction ${transactionId}`,
              },
            ]
          : []),
      ],
      async (data) => {
        const entry = returnable.find(
          (item: Json) => item.line.id === data.lineId,
        );
        if (!entry) throw new Error("Choose the invoice line being returned.");
        const quantity = Number(data.quantity);
        if (!Number.isInteger(quantity) || quantity < 1 || quantity > entry.remaining)
          throw new Error(`Return between 1 and ${entry.remaining} units of this line.`);
        if (entry.line.type !== "service") {
          const bin = bins.find((item) => item.id === data.binId);
          if (!bin) throw new Error("Choose the bin receiving the returned stock.");
          if (bin.kind !== data.condition)
            throw new Error(`Choose a ${data.condition} bin for ${data.condition} returns.`);
        }
        if (entry.line.serials?.length && list(data.serials).length !== quantity)
          throw new Error("Enter one returned serial number for each unit.");
        const approvalId = manager
          ? await approval("return", transactionId, data.reason)
          : data.approvalId;
        await mutate(
          `/invoices/${invoice.id}/returns`,
          {
            ...data,
            transactionId,
            approvalId,
            lines: [
              {
                lineId: data.lineId,
                quantity: Number(data.quantity),
                binId: data.binId,
                serials: list(data.serials),
              },
            ],
          },
          "Return, refund, and destination stock recorded.",
        );
      },
      "Record return",
    );
  }
  function transferStock() {
    form(
      "Dispatch branch transfer",
      [
        {
          name: "destinationBranchId",
          label: "Destination branch",
          options: options(
            (snapshot.branches || []).filter(
              (branch: Json) => branch.id !== session?.branchId,
            ),
          ),
          required: true,
        },
        partField(),
        binField("binId", "Source bin", "sellable"),
        quantityField(),
        { name: "serials", label: "Serial numbers (serial-tracked parts only)", help: "Separate with commas.", advanced: true },
        reasonField,
      ],
      async (data) => {
        await mutate(
          "/transfers",
          {
            destinationBranchId: data.destinationBranchId,
            reason: data.reason,
            lines: [
              {
                productId: data.productId,
                binId: data.binId,
                quantity: Number(data.quantity),
                serials: list(data.serials),
              },
            ],
          },
          "Transfer dispatched.",
        );
      },
      "Dispatch",
    );
  }
  function receiveTransfer(transfer: Json) {
    form(
      "Receive branch transfer",
      [
        {
          name: "productId",
          label: "Part",
          options: transfer.lines.map((line: Json) => ({
            value: line.productId,
            label: productName(line.productId),
          })),
          required: true,
        },
        binField("binId", "Receive into bin", "sellable"),
        quantityField(),
        { name: "serials", label: "Serial numbers (serial-tracked parts only)", help: "Separate with commas.", advanced: true },
      ],
      async (data) => {
        await mutate(
          `/transfers/${transfer.id}/receive`,
          {
            lines: [
              {
                ...data,
                quantity: Number(data.quantity),
                serials: list(data.serials),
              },
            ],
          },
          "Transfer received.",
        );
      },
    );
  }
  function enrollDevice() {
    form(
      "Enroll this counter",
      [
        {
          name: "name",
          label: "Device name",
          value: "Counter 01",
          required: true,
        },
        {
          name: "offlineAllowed",
          label: "Offline checkout",
          options: [
            { value: "true", label: "Allowed within assigned invoice range" },
            { value: "false", label: "Online only" },
          ],
          value: "true",
        },
        {
          advanced: true,
          name: "offlineHours",
          label: "Offline authorization hours",
          type: "number",
          min: 0,
          value: Math.min(24, snapshot.settings?.offlineHours ?? 24),
          help: `Organization maximum: ${snapshot.settings?.offlineHours ?? 0} hours.`,
          required: true,
        },
        {
          advanced: true,
          name: "rangeSize",
          label: "Invoice range size",
          type: "number",
          min: 10,
          value: 1000,
          required: true,
        },
      ],
      async (data) => {
        const device = await api("/devices/enroll", {
          ...data,
          offlineAllowed: data.offlineAllowed === "true",
          offlineHours: Number(data.offlineHours),
          rangeSize: Number(data.rangeSize),
          tenders: snapshot.settings?.offlineTenders ?? ["Cash"],
        });
        await locked(deviceKey(session!), async () => {
          const latest = (await readLocal<Workspace>(scopeKey(session!)))!;
          await writeLocal(deviceKey(session!), {
            device,
            nextInvoice: device.rangeStart,
          });
          await persistWorkspace({
            ...latest,
            device,
            nextInvoice: device.rangeStart ?? device.invoiceRangeStart,
          });
        });
        toast(
          "Device enrolled. Cash checkout is available within the offline authorization.",
        );
      },
      "Enroll device",
    );
  }
  function openShift(thenCheckout = false) {
    form(
      "Open shift",
      [
        {
          name: "openingCash",
          label: "Opening cash in drawer",
          type: "number",
          step: "0.01",
          min: 0,
          value: 0,
          required: true,
          help: thenCheckout
            ? "A shift is required before checkout. Checkout continues after the shift opens."
            : undefined,
        },
      ],
      async (data) => {
        const shift = await mutate(
          "/shifts/open",
          { openingCash: Math.round(Number(data.openingCash) * 100) },
          "Shift opened.",
        );
        updateCart({ shiftId: shift.id });
        if (thenCheckout) resumeCheckout.current = true;
      },
      "Open shift",
    );
  }
  function expectedCash(shift: Json) {
    const cashSales = (snapshot.invoices || [])
      .filter((sale: Json) => sale.shiftId === shift.id)
      .reduce(
        (sum: number, sale: Json) =>
          sum +
          (sale.tenders || [])
            .filter((tender: Json) => tender.type === "Cash")
            .reduce((n: number, tender: Json) => n + tender.amount, 0) -
          (sale.change || 0),
        0,
      );
    const refunds = [...(snapshot.returns || []), ...(snapshot.coreReturns || [])]
      .filter((item: Json) => item.shiftId === shift.id && (item.refundType || "Cash") === "Cash")
      .reduce((sum: number, item: Json) => sum + (item.total || 0), 0);
    return (shift.openingCash || 0) + cashSales - refunds;
  }
  function closeShift(shift: Json) {
    form(
      "Close shift",
      [
        {
          name: "countedCash",
          label: "Cash counted in drawer",
          type: "number",
          min: 0,
          step: "0.01",
          required: true,
          help: manager
            ? `Expected about ${money(expectedCash(shift))}. The server records the final variance.`
            : "Count the drawer before closing. The server records any variance.",
        },
        { ...reasonField, label: "Closing note", value: "Shift close" },
      ],
      async (data) => {
        await mutate(
          `/shifts/${shift.id}/close`,
          {
            countedCash: Math.round(Number(data.countedCash) * 100),
            reason: data.reason,
          },
          "Shift closed and cash variance recorded.",
        );
      },
    );
  }

  function viewForSection() {
    const q = normalize(search);
    const matching = (records: Json[]) =>
      records.filter(
        (item) => !q || normalize(JSON.stringify(item)).includes(q),
      );
    if (section === "Dashboard") {
      const today = new Date().toLocaleDateString("en-CA");
      const sales = (snapshot.invoices || []).filter(
        (invoice: Json) =>
          new Date(invoice.createdAt).toLocaleDateString("en-CA") === today,
      );
      const returns = (snapshot.returns || []).filter(
        (item: Json) =>
          new Date(item.createdAt).toLocaleDateString("en-CA") === today,
      );
      const gross = sales.reduce(
        (sum: number, sale: Json) => sum + sale.total,
        0,
      );
      const refunded = returns.reduce(
        (sum: number, item: Json) => sum + item.total,
        0,
      );
      return (
        <>
          <div className="metrics">
            {[
              ["Confirmed sales today", sales.length],
              ["Confirmed net sales", money(gross - refunded)],
              ["Refunds today", money(refunded)],
              [
                "Pending on this counter",
                money(
                  (workspace?.pending || []).reduce(
                    (sum, item) => sum + item.localQuote.total,
                    0,
                  ),
                ),
              ],
            ].map(([label, value]) => (
              <div className="metric" key={label}>
                <span>{label}</span>
                <strong>{value}</strong>
              </div>
            ))}
          </div>
          <h2>Low-stock parts</h2>
          <DataTable
            rows={products.filter(
              (product) =>
                product.type !== "service" &&
                available(product.id) <= product.reorderLevel,
            )}
            columns={[
              ["Part", (product) => product.name],
              ["Available", (product) => available(product.id)],
              ["Reorder level", (product) => product.reorderLevel],
              [
                "Suggested order",
                (product) =>
                  Math.max(0, product.reorderLevel * 2 - available(product.id)),
              ],
            ]}
          />
          <h2>Recent confirmed invoices</h2>
          <DataTable
            rows={[...(snapshot.invoices || [])].reverse().slice(0, 10)}
            columns={[
              ["Invoice", (item) => item.number],
              ["Date", (item) => formatDate(item.createdAt)],
              ["Total", (item) => money(item.total)],
            ]}
            action={(item) => (
              <button className="button" onClick={() => setReceipt(item)}>
                View receipt
              </button>
            )}
          />
        </>
      );
    }
    if (section === "Inventory")
      return (
        <>
          <div className="section-toolbar">
            {inventoryRole && (
              <>
                <button
                  className="primary-button"
                  onClick={() => editProduct()}
                >
                  Add part
                </button>
                <button
                  className="button"
                  onClick={() => stockOperation("adjust")}
                >
                  Adjust stock
                </button>
                <button
                  className="button"
                  onClick={() => stockOperation("count")}
                >
                  Stock count
                </button>
                <button
                  className="button"
                  onClick={() =>
                    printLabels(
                      matching(products).map(productLabel),
                      search ? `Labels · ${matching(products).length} matching parts` : `Labels · all ${products.length} parts`,
                    )
                  }
                >
                  Print labels
                </button>
              </>
            )}
          </div>
          <DataTable
            rows={matching(products)}
            columns={[
              [
                "Part",
                (product) => (
                  <>
                    <strong>{product.name}</strong>
                    <small>
                      {product.sku} · {product.partNumber}
                    </small>
                  </>
                ),
              ],
              [
                "OEM / barcodes",
                (product) => (
                  <>
                    {(product.oemReferences || []).join(", ")}
                    <small>{(product.barcodes || []).join(", ")}</small>
                  </>
                ),
              ],
              ["Available", (product) => available(product.id)],
              [
                "Bins",
                (product) =>
                  stock
                    .filter(
                      (item) => item.productId === product.id && item.quantity,
                    )
                    .map((item) => (
                      <small key={item.binId}>
                        {locationName(item.binId)} · {item.quantity}
                      </small>
                    )),
              ],
              [
                "Retail / wholesale",
                (product) => (
                  <>
                    {money(product.retailPrice)}
                    <small>{money(product.wholesalePrice)}</small>
                  </>
                ),
              ],
              ...(inventoryRole
                ? ([["Cost", (product: Json) => money(product.cost)]] as [string, (item: Json) => React.ReactNode][])
                : []),
            ]}
            action={(product) =>
              inventoryRole && (
                <>
                  <button
                    className="button"
                    onClick={() => editProduct(product)}
                  >
                    Edit
                  </button>
                  {features.fitment && <button
                    className="button"
                    onClick={() => editFitment(product.id)}
                  >
                    Fitment
                  </button>}
                  <button
                    className="button"
                    onClick={() => printLabel(product)}
                  >
                    Label
                  </button>
                </>
              )
            }
          />
        </>
      );
    if (section === "Locations")
      return (
        <>
          <div className="section-toolbar">
            {inventoryRole && (
              <>
                <button
                  className="primary-button"
                  onClick={() => editLocation()}
                >
                  Add location
                </button>
                <button
                  className="button"
                  onClick={() => stockOperation("move")}
                >
                  Move stock
                </button>
                <button
                  className="button"
                  onClick={() =>
                    printLabels(
                      matching(bins).map((bin) => ({ name: binName(bin), code: bin.id, sku: bin.kind })),
                      "Bin labels",
                    )
                  }
                >
                  Print bin labels
                </button>
              </>
            )}
          </div>
          <DataTable
            rows={matching(bins)}
            columns={[
              ["Location", binName],
              ["Condition", (bin) => bin.kind],
              [
                "Quantity",
                (bin) =>
                  stock
                    .filter((item) => item.binId === bin.id)
                    .reduce((sum, item) => sum + item.quantity, 0),
              ],
            ]}
            action={(bin) =>
              inventoryRole && (
                <>
                  <button className="button" onClick={() => editLocation(bin)}>
                    Rename
                  </button>
                  <button
                    className="button"
                    onClick={() =>
                      printLabel({
                        name: binName(bin),
                        sku: bin.id,
                        barcodes: [bin.id],
                      })
                    }
                  >
                    Label
                  </button>
                </>
              )
            }
          />
        </>
      );
    if (section === "Purchasing")
      return (
        <>
          <div className="section-toolbar">
            {inventoryRole && (
              <button className="primary-button" onClick={createPurchase}>
                New purchase order
              </button>
            )}
          </div>
          <DataTable
            rows={matching([...(snapshot.purchaseOrders || [])].reverse())}
            columns={[
              ["Created", (order) => formatDate(order.createdAt)],
              [
                "Supplier",
                (order) =>
                  (snapshot.suppliers || []).find(
                    (supplier: Json) => supplier.id === order.supplierId,
                  )?.name || "—",
              ],
              [
                "Status",
                (order) => (
                  <span className={`status-chip status-${order.status}`}>{titleCase(order.status)}</span>
                ),
              ],
              [
                "Value",
                (order) =>
                  money(
                    (order.lines || []).reduce(
                      (sum: number, line: Json) => sum + line.quantity * line.cost,
                      0,
                    ),
                  ),
              ],
              [
                "Lines",
                (order) =>
                  order.lines.map((line: Json) => (
                    <small key={line.productId}>
                      {productName(line.productId)} · {line.quantity} ordered /{" "}
                      {line.received || 0} received
                    </small>
                  )),
              ],
            ]}
            action={(order) =>
              inventoryRole &&
              order.status !== "received" && (
                <button
                  className="button"
                  onClick={() => receivePurchase(order)}
                >
                  Receive stock
                </button>
              )
            }
          />
        </>
      );
    if (section === "Customers" || section === "Suppliers") {
      const kind = section.toLowerCase();
      return (
        <>
          <div className="section-toolbar">
            <button className="primary-button" onClick={() => addContact(kind)}>
              Add {kind === "customers" ? "customer" : "supplier"}
            </button>
          </div>
          <DataTable
            rows={matching(snapshot[kind] || [])}
            columns={[
              ["Name", (person) => person.name],
              ["Phone", (person) => person.phone],
              ["Email", (person) => person.email],
              ["Tax registration", (person) => person.taxRegistrationId],
            ]}
            action={(person) => <button className="button" onClick={() => addContact(kind, person)}>Edit</button>}
          />
        </>
      );
    }
    if (section === "Sales history")
      return (
        <>
          <h2>Invoices</h2>
          <DataTable
            rows={matching([...(snapshot.invoices || [])].reverse())}
            columns={[
              ["Invoice", (invoice) => invoice.number],
              ["Date", (invoice) => formatDate(invoice.createdAt)],
              [
                "Customer",
                (invoice) => invoice.customer?.name || "Walk-in",
              ],
              [
                "Status",
                (invoice) => (
                  <span className={`status-chip status-${normalize(invoiceStatus(invoice))}`}>
                    {invoiceStatus(invoice)}
                  </span>
                ),
              ],
              ["Total", (invoice) => money(invoice.total)],
              ["Cashier", (invoice) => userName(invoice.cashierId)],
            ]}
            action={(invoice) => {
              const status = invoiceStatus(invoice);
              const open = !["Voided", "Returned"].includes(status);
              return (
                <>
                  <button className="button" onClick={() => setReceipt(invoice)}>
                    Receipt
                  </button>
                  {open && canSell && (
                    <button className="button" onClick={() => returnInvoice(invoice)}>
                      Return
                    </button>
                  )}
                  {manager && status === "Finalized" && (
                    <button
                      className="button danger-button"
                      onClick={() =>
                        form(
                          `Void ${invoice.number}`,
                          [
                            reasonField,
                            {
                              name: "refundType",
                              label: "Refund method",
                              options: tenderTypes.map((value) => ({ value, label: value })),
                              value: invoice.tenders?.[0]?.type || "Cash",
                              required: true,
                            },
                          ],
                          async (data) => {
                            const result = await mutate(
                              `/invoices/${invoice.id}/void`,
                              data,
                              "Invoice voided. Stock returned and credit note issued.",
                            );
                            if (result?.totalRefund !== undefined)
                              toast(`Invoice voided. Refund ${money(result.totalRefund)} by ${data.refundType}.`);
                          },
                          "Void invoice",
                        )
                      }
                    >
                      Void
                    </button>
                  )}
                </>
              );
            }}
          />
          <h2>Credit notes</h2>
          <DataTable
            rows={matching([...(snapshot.returns || [])].reverse())}
            columns={[
              ["Credit note", (item) => item.number || item.id],
              ["Invoice", (item) => item.invoiceNumber || item.invoiceId],
              ["Date", (item) => formatDate(item.createdAt)],
              ["Type", (item) => (item.voided ? "Void" : "Return")],
              ["Condition", (item) => titleCase(item.condition || "")],
              ["Refund", (item) => `${money(item.total)} · ${item.refundType || "Cash"}`],
            ]}
            action={(item) => (
              <button className="button" onClick={() => setReceipt(item)}>
                View
              </button>
            )}
          />
        </>
      );
    if (section === "Transfers")
      return (
        <>
          <div className="section-toolbar">
            {inventoryRole && (
              <button className="primary-button" onClick={transferStock}>
                Dispatch transfer
              </button>
            )}
          </div>
          <DataTable
            rows={matching(snapshot.transfers || [])}
            columns={[
              ["Date", (item) => formatDate(item.createdAt)],
              ["From", (item) => branchLabel(item.branchId || item.sourceBranchId)],
              ["To", (item) => branchLabel(item.destinationBranchId)],
              [
                "Parts",
                (item) =>
                  (item.lines || []).map((line: Json) => (
                    <small key={line.id || line.productId}>
                      {productName(line.productId)} · {line.received || 0}/{line.quantity} received
                    </small>
                  )),
              ],
              [
                "Status",
                (item) => (
                  <span className={`status-chip status-${item.status}`}>{titleCase(item.status)}</span>
                ),
              ],
            ]}
            action={(item) =>
              inventoryRole &&
              item.status !== "received" &&
              item.destinationBranchId === session?.branchId && (
                <button
                  className="button"
                  onClick={() => receiveTransfer(item)}
                >
                  Receive
                </button>
              )
            }
          />
        </>
      );
    if (section === "Fitment")
      return (
        <>
          <div className="section-toolbar">
            {inventoryRole && (
              <>
                <button
                  className="primary-button"
                  onClick={() => editFitment()}
                >
                  Add fitment rule
                </button>
                <button className="button" onClick={csvImport}>
                  Import CSV
                </button>
              </>
            )}
          </div>
          <DataTable
            rows={matching(
              products.flatMap((product) =>
                (product.fitments || []).map((fit: Json) => ({
                  ...fit,
                  productId: product.id,
                })),
              ),
            )}
            columns={[
              ["Part", (fit) => productName(fit.productId)],
              ["Vehicle", (fit) => `${fit.make} ${fit.model}`],
              ["Years", (fit) => `${fit.yearFrom}–${fit.yearTo}`],
              [
                "Qualifiers",
                (fit) =>
                  [fit.engine, fit.fuel, fit.trim, fit.drivetrain, fit.market]
                    .filter(Boolean)
                    .join(" · "),
              ],
              ["Source", (fit) => fit.source],
              [
                "Effective",
                (fit) =>
                  `${fit.effectiveFrom || "—"} / ${fit.effectiveTo || "ongoing"}`,
              ],
            ]}
          />
        </>
      );
    if (section === "Shifts")
      return (
        <>
          <div className="section-toolbar">
            {(snapshot.shifts || []).some(
              (shift: Json) => !shift.closedAt && shift.userId === session?.user.id,
            ) ? (
              <p>Your shift is open.</p>
            ) : (
              <button className="primary-button" onClick={() => openShift()}>
                Open shift
              </button>
            )}
          </div>
          <DataTable
            rows={[...(snapshot.shifts || [])].reverse()}
            columns={[
              ["Cashier", (shift) => userName(shift.userId)],
              [
                "Opened",
                (shift) => formatDate(shift.openedAt || shift.createdAt),
              ],
              ["Closed", (shift) => (shift.closedAt ? formatDate(shift.closedAt) : "—")],
              ["Opening cash", (shift) => money(shift.openingCash)],
              [
                "Expected cash",
                (shift) =>
                  shift.closedAt
                    ? money(shift.expectedCash)
                    : manager
                      ? money(expectedCash(shift))
                      : "—",
              ],
              ["Counted", (shift) => (shift.closedAt ? money(shift.countedCash) : "—")],
              [
                "Variance",
                (shift) =>
                  shift.closedAt ? (
                    <span className={shift.variance ? "fit-incompatible" : "fit-compatible"}>
                      {money(shift.variance || 0)}
                    </span>
                  ) : (
                    "—"
                  ),
              ],
              [
                "Status",
                (shift) => (
                  <span className={`status-chip status-${shift.closedAt ? "closed" : "open"}`}>
                    {shift.closedAt ? "Closed" : "Open"}
                  </span>
                ),
              ],
            ]}
            action={(shift) =>
              !shift.closedAt &&
              (manager || shift.userId === session?.user.id) && (
                <button className="button" onClick={() => closeShift(shift)}>
                  Close shift
                </button>
              )
            }
          />
        </>
      );
    if (section === "Reconciliation")
      return (
        <>
          <div className="section-toolbar">
            <button
              className="primary-button"
              onClick={() => refresh("Synchronization checked.")}
            >
              Synchronize now
            </button>
          </div>
          {(features.offline || (workspace?.pending || []).length > 0 || (snapshot.conflicts || []).length > 0) && <>
          <h2>Pending on this device</h2>
          <DataTable
            rows={workspace?.pending || []}
            columns={[
              ["Transaction", (item) => item.transaction.transactionId],
              ["Created", (item) => formatDate(item.createdAt)],
              ["Total", (item) => money(item.localQuote.total)],
              ["Status", (item) => item.error || item.status || "Pending sync"],
            ]}
            action={(item) =>
              item.status === "awaiting-payment" && (
                <button
                  className="button"
                  onClick={() =>
                    form(
                      "Confirm provider payment",
                      [
                        {
                          name: "reference",
                          label: "Confirmed provider reference",
                          required: true,
                        },
                      ],
                      async (data) => {
                        await locked(deviceKey(session!), async () => {
                          const latest = (await readLocal<Workspace>(
                            scopeKey(session!),
                          ))!;
                          const next = {
                            ...latest,
                            pending: latest.pending.map((entry) =>
                              entry.transaction.transactionId ===
                              item.transaction.transactionId
                                ? {
                                    ...entry,
                                    status: "pending",
                                    transaction: {
                                      ...entry.transaction,
                                      tenders: entry.transaction.tenders.map(
                                        (tender: Json) => ({
                                          ...tender,
                                          confirmed: true,
                                          reference: data.reference,
                                        }),
                                      ),
                                    },
                                  }
                                : entry,
                            ),
                          };
                          await persistWorkspace(next);
                        });
                        await refresh("Provider confirmation saved.");
                      },
                      "Confirm payment",
                    )
                  }
                >
                  Confirm payment
                </button>
              )
            }
          />
          <h2>Stock conflicts</h2>
          <DataTable
            rows={snapshot.conflicts || []}
            columns={[
              ["Conflict", (item) => item.id],
              ["Reason", (item) => item.reason || item.error || item.message],
              ["Status", (item) => item.status],
            ]}
            action={(item) =>
              manager &&
              item.status === "pending" && (
                <button
                  className="button"
                  onClick={() =>
                    form(
                      "Resolve stock conflict",
                      [
                        {
                          name: "action",
                          label: "Decision",
                          options: [
                            {
                              value: "accept",
                              label: "Accept sale and record stock variance",
                            },
                            {
                              value: "reject",
                              label: "Reject sale for manual refund",
                            },
                          ],
                          required: true,
                        },
                        reasonField,
                      ],
                      async (data) => {
                        await mutate(
                          `/conflicts/${item.id}/resolve`,
                          data,
                          "Reconciliation recorded in the audit trail.",
                        );
                      },
                    )
                  }
                >
                  Resolve
                </button>
              )
            }
          />
          </>}
          {manager && <h2>Audit trail</h2>}
          <DataTable
            rows={(snapshot.audit || []).slice(-100).reverse()}
            columns={[
              ["Time", (item) => formatDate(item.createdAt)],
              ["User", (item) => userName(item.userId || item.actorId || item.actor?.id)],
              ["Action", (item) => humanize(item.action || "")],
              ["Reason", (item) => item.reason || item.details?.reason || "—"],
            ]}
          />
        </>
      );
    if (section === "Warranty & cores")
      return (
        <>
          <div className="section-toolbar">
            <button
              className="primary-button"
              onClick={() =>
                form(
                  "Supplier warranty claim",
                  [
                    {
                      name: "returnId",
                      label: "Warranty return",
                      options: options(
                        (snapshot.returns || []).filter(
                          (item: Json) =>
                            item.condition === "warranty" &&
                            !(snapshot.warrantyClaims || []).some(
                              (claim: Json) => claim.returnId === item.id,
                            ),
                        ),
                        (item) =>
                          `${item.number || item.id} · ${(item.lines || [])
                            .map((line: Json) => line.name || productName(line.productId))
                            .join(", ")}`,
                      ),
                      required: true,
                      help: "Record a return with the warranty condition first.",
                    },
                    {
                      name: "supplierId",
                      label: "Supplier",
                      options: options(snapshot.suppliers || []),
                      required: true,
                    },
                    reasonField,
                  ],
                  async (data) => {
                    await mutate(
                      "/warranty-claims",
                      { ...data, status: "open" },
                      "Warranty claim created.",
                    );
                  },
                )
              }
            >
              Create warranty claim
            </button>
            {manager && <button
              className="button"
              onClick={() => {
                const withCores = (snapshot.invoices || []).filter(
                  (invoice: Json) =>
                    invoiceStatus(invoice) !== "Voided" &&
                    (invoice.lines || []).some((line: Json) => line.coreCharge > 0),
                );
                if (!withCores.length) {
                  toast("No invoices in this branch carry a refundable core charge.");
                  return;
                }
                form(
                  "Record core return",
                  [
                    {
                      name: "invoiceId",
                      label: "Original invoice",
                      options: options(withCores, (invoice) => `${invoice.number} · ${formatDate(invoice.createdAt)}`),
                      required: true,
                    },
                    {
                      ...partField(),
                      options: options(
                        products.filter((product) => product.coreCharge > 0),
                        (product) => `${product.sku} · ${product.name} · core ${money(product.coreCharge)}`,
                      ),
                    },
                    quantityField(),
                    {
                      name: "refundType",
                      label: "Refund method",
                      options: tenderTypes.map((value) => ({ value, label: value })),
                      value: "Cash",
                      required: true,
                    },
                    reasonField,
                  ],
                  async (data) => {
                    await mutate(
                      "/core-returns",
                      {
                        ...data,
                        transactionId: crypto.randomUUID(),
                        quantity: Number(data.quantity),
                      },
                      "Core charge refund recorded.",
                    );
                  },
                  "Record refund",
                );
              }}
            >
              Receive core
            </button>}
          </div>
          <h2>Warranty claims</h2>
          <DataTable
            rows={snapshot.warrantyClaims || []}
            columns={[
              [
                "Return",
                (item) =>
                  (snapshot.returns || []).find((entry: Json) => entry.id === item.returnId)
                    ?.number || item.returnId,
              ],
              [
                "Supplier",
                (item) =>
                  (snapshot.suppliers || []).find((entry: Json) => entry.id === item.supplierId)
                    ?.name || "—",
              ],
              [
                "Status",
                (item) => (
                  <span className={`status-chip status-${item.status}`}>{titleCase(item.status)}</span>
                ),
              ],
              ["Reason", (item) => item.reason],
              ["Updated", (item) => formatDate(item.updatedAt || item.createdAt)],
            ]}
            action={(claim) => (
              <button
                className="button"
                onClick={() =>
                  form(
                    "Update warranty claim",
                    [
                      {
                        name: "status",
                        label: "Status",
                        options: [
                          "open",
                          "sent",
                          "approved",
                          "rejected",
                          "settled",
                        ].map((value) => ({ value, label: value })),
                        value: claim.status,
                      },
                      reasonField,
                    ],
                    async (data) => {
                      await mutate(
                        "/warranty-claims",
                        { ...claim, ...data },
                        "Warranty status updated.",
                      );
                    },
                  )
                }
              >
                Update status
              </button>
            )}
          />
          <h2>Core refunds</h2>
          <DataTable
            rows={snapshot.coreReturns || []}
            columns={[
              [
                "Invoice",
                (item) =>
                  (snapshot.invoices || []).find((invoice: Json) => invoice.id === item.invoiceId)
                    ?.number || item.invoiceId,
              ],
              ["Date", (item) => formatDate(item.createdAt)],
              ["Part", (item) => productName(item.productId)],
              ["Quantity", (item) => item.quantity],
              ["Refund", (item) => `${money(item.total || item.amount)} · ${item.refundType || "Cash"}`],
            ]}
          />
        </>
      );
    if (section === "Reports")
      return (
        <>
          <form className="report-form" onSubmit={loadReport}>
            <FieldInput
              field={{
                name: "name",
                label: "Report",
                options: reportNames
                  .filter((value) => manager || inventoryReports.includes(value))
                  .map((value) => ({
                    value,
                    label: humanize(value),
                  })),
                value: "sales",
                required: true,
              }}
            />
            <FieldInput
              field={{
                name: "dateFrom",
                label: "From",
                type: "date",
              }}
            />
            <FieldInput field={{ name: "dateTo", label: "To", type: "date" }} />
            <button className="primary-button" type="submit">
              Run report
            </button>
            <details className="more-options report-filters">
              <summary>More filters</summary>
              <div className="report-form-extra">
            <FieldInput field={{ name: "category", label: "Category" }} />
            <FieldInput field={{ name: "sku", label: "SKU" }} />
            <FieldInput
              field={{
                name: "supplierId",
                label: "Supplier",
                options: options(snapshot.suppliers || []),
              }}
            />
            {(snapshot.users || []).length > 0 ? (
              <FieldInput
                field={{
                  name: "cashier",
                  label: "Cashier",
                  options: options(snapshot.users || [], (user) => user.name || user.email),
                }}
              />
            ) : (
              <FieldInput field={{ name: "cashier", label: "Cashier ID" }} />
            )}
            <FieldInput
              field={{
                name: "paymentType",
                label: "Payment",
                options: tenderTypes.map((value) => ({
                  value,
                  label: value,
                })),
              }}
            />
              </div>
            </details>
          </form>
          {report && (
            <>
              <div className="section-toolbar">
                <h2>{humanize(report.name)} report</h2>
                <button className="button" onClick={exportReport} disabled={!report.rows?.length}>
                  Export CSV
                </button>
                <button className="button" onClick={() => window.print()}>
                  Print summary
                </button>
              </div>
              <div className="metrics">
                {Object.entries(report.totals || {}).map(([name, value]) => (
                  <div className="metric" key={name}>
                    <span>{humanize(name)}</span>
                    <strong>{reportCell(name, value)}</strong>
                  </div>
                ))}
              </div>
              {report.pendingConflicts > 0 && (
                <p className="form-hint">
                  {report.pendingConflicts} offline sale conflict(s) await manager review and are excluded.
                </p>
              )}
              <DataTable
                rows={report.rows || []}
                columns={[
                  ...new Set<string>(
                    (report.rows || []).slice(0, 50).flatMap((row: Json) => Object.keys(row)),
                  ),
                ]
                  .filter(
                    (key) =>
                      !hiddenReportKeys.has(key) &&
                      typeof report.rows.find((row: Json) => row[key] != null)?.[key] !== "object",
                  )
                  .map((key) => [
                    humanize(key.replace(/^(cashier|user)Id$/, "$1")),
                    (item: Json) => reportCell(key, item[key]),
                  ])}
                action={(item) =>
                  item.invoiceId && (
                    <button
                      className="button"
                      onClick={() =>
                        setReceipt(
                          snapshot.invoices.find(
                            (invoice: Json) => invoice.id === item.invoiceId,
                          ),
                        )
                      }
                    >
                      Invoice
                    </button>
                  )
                }
              />
            </>
          )}
        </>
      );
    if (section === "Settings") {
      const business = snapshot.settings?.business || {};
      const enabled = (["transfers", "fitment", "offline", "warranty"] as Feature[]).filter(
        (key) => features[key],
      );
      return (
        <div className="settings-panel">
          {role === "owner" && (!business.legalName || !business.address) && (
            <div className="setup-note">
              <strong>Finish setting up your shop</strong>
              <p>Add the legal business name and address. They are printed on every receipt.</p>
              <button className="primary-button" onClick={editBusiness}>Add business details</button>
            </div>
          )}
          <div className="settings-cards">
            {role === "owner" && (
              <section className="settings-card">
                <h2>Shop</h2>
                <p>
                  <strong>{business.tradingName || business.legalName || snapshot.organization?.name || "Your business"}</strong>
                  <br />
                  {snapshot.branch?.name}
                  {business.taxRegistrationId ? ` · GSTIN ${business.taxRegistrationId}` : ""}
                </p>
                <p>
                  {snapshot.settings?.taxScheme === "india-gst" ? "India GST" : "General tax"} · prices{" "}
                  {snapshot.settings?.taxMode === "inclusive" ? "include" : "exclude"} tax · {tenderTypes.join(", ")}
                </p>
                <div className="section-toolbar">
                  <button className="button" onClick={editBusiness}>Business details</button>
                  <button className="button" onClick={editRegisterSettings}>Edit settings</button>
                  <button className="button" onClick={editModules}>Modules</button>
                </div>
                <small>
                  Modules on: {enabled.length ? enabled.map(featureLabel).join(", ") : "core billing and stock only"}
                </small>
              </section>
            )}
            <section className="settings-card">
              <h2>You</h2>
              <p>
                <strong>{session?.user.name || session?.user.email}</strong> · {titleCase(role || "")}
                <br />
                {snapshot.branch?.name} · session ends {formatDate(session?.expiresAt || "")}
              </p>
              <p>Last synced {formatDate(workspace?.lastSync || "")}</p>
              <div className="section-toolbar">
                {manager && (
                  <button className="button" onClick={issueApproval}>Issue approval</button>
                )}
                {manager && features.offline && (
                  <button className="button" onClick={enrollDevice}>Enroll counter</button>
                )}
                <button
                  className="button"
                  onClick={async () => {
                    await locked(deviceKey(session!), async () => {
                      await writeLocal("active-session", null);
                      setSession(null);
                      setWorkspace(null);
                      setCart(null);
                    });
                  }}
                >
                  Sign out / change branch
                </button>
              </div>
              {features.offline && (
                <small>
                  {workspace?.device
                    ? `Counter "${workspace.device.name}" can sell offline until ${formatDate(workspace.device.offlineUntil)}.`
                    : "This counter sells online only until it is enrolled."}
                </small>
              )}
            </section>
          </div>
          {role === "owner" && (
            <>
              <div className="section-heading-row">
                <h2>Staff</h2>
                <button className="button" onClick={() => editUser()}>Add staff</button>
              </div>
              <DataTable
                rows={snapshot.users || []}
                columns={[
                  ["Name", (item) => item.name],
                  ["Email", (item) => item.email],
                  ["Role", (item) => titleCase(item.role)],
                  ["Branches", (item) => (item.branchIds || []).map(branchLabel).join(", ")],
                  [
                    "Status",
                    (item) => (
                      <span className={`status-chip status-${item.active ? "received" : "voided"}`}>
                        {item.active ? "Active" : "Disabled"}
                      </span>
                    ),
                  ],
                ]}
                action={(item) => <button className="button" onClick={() => editUser(item)}>Edit</button>}
              />
              <div className="section-heading-row">
                <h2>Branches</h2>
                <button className="button" onClick={() => editBranch()}>Add branch</button>
              </div>
              <DataTable
                rows={snapshot.branches || []}
                columns={[
                  ["Code", (item) => item.id],
                  ["Name", (item) => item.name],
                  ["Address", (item) => item.address || "—"],
                ]}
                action={(item) => <button className="button" onClick={() => editBranch(item)}>Edit</button>}
              />
            </>
          )}
        </div>
      );
    }
    return null;
  }

  function featureLabel(key: Feature) {
    return {
      transfers: "branch transfers",
      fitment: "vehicle fitment",
      offline: "offline counters",
      warranty: "warranty & cores",
    }[key];
  }
  function editModules() {
    form(
      "Modules",
      [
        {
          name: "features",
          label: "Switch on only what the shop uses",
          type: "checks",
          options: (["fitment", "transfers", "warranty", "offline"] as Feature[]).map((key) => ({
            value: key,
            label: titleCase(featureLabel(key)),
          })),
          value: (["transfers", "fitment", "offline", "warranty"] as Feature[]).filter(
            (key) => features[key],
          ),
          help: "Switched-off modules are hidden on every counter. Their records are kept and come back when switched on.",
        },
      ],
      async (data) => {
        const on = new Set<string>(data.features || []);
        await mutate(
          "/settings",
          {
            features: Object.fromEntries(
              ["transfers", "fitment", "offline", "warranty"].map((key) => [key, on.has(key)]),
            ),
          },
          "Modules updated.",
        );
      },
    );
  }
  function issueApproval() {
    form(
      "Issue approval",
      [
        {
          name: "action",
          label: "What the cashier needs",
          options: [
            { value: "discount", label: "Discount above their limit" },
            { value: "return", label: "Return or refund" },
            { value: "fitment", label: "Part that may not fit the vehicle" },
            { value: "adjustment", label: "Stock adjustment" },
          ],
          required: true,
        },
        {
          name: "transactionId",
          label: "Transaction ID shown on the cashier's screen",
          required: true,
        },
        reasonField,
      ],
      async (data) => {
        const result = await api("/approvals", data);
        setTimeout(
          () =>
            setModal({
              title: "Approval issued",
              content: (
                <>
                  <p>Read this ID to the cashier. It works once and expires in 15 minutes.</p>
                  <code className="approval-code">{result.id}</code>
                </>
              ),
            }),
          0,
        );
      },
      "Issue approval",
    );
  }
  async function loadReport(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    try {
      const values = Object.fromEntries(
        new FormData(event.currentTarget),
      ) as Record<string, string>;
      const { name, ...filters } = values;
      setReport(
        await api(
          `/reports/${name}?${new URLSearchParams(Object.entries(filters).filter(([, value]) => value))}`,
        ),
      );
    } catch (reason) {
      fail(reason);
    }
  }
  function reportCell(key: string, value: any): React.ReactNode {
    if (value === null || value === undefined || value === "") return "—";
    if (typeof value === "number") {
      if (moneyKeys.has(key)) return money(value);
      if (key === "taxRate") return `${value / 100}%`;
      return value.toLocaleString("en-IN");
    }
    if (typeof value === "boolean") return value ? "Yes" : "No";
    if (/^(cashierId|userId|approvedBy|resolvedBy)$/.test(key)) return userName(value);
    if (key === "location" || key === "binId") return locationName(value);
    if (/(At|date|Date)$/.test(key) && /^\d{4}-\d{2}-\d{2}T/.test(String(value)))
      return formatDate(String(value));
    return String(value);
  }
  function exportReport() {
    if (!report?.rows.length) return;
    const keys = Object.keys(report.rows[0]);
    const safeCell = (value: any) => {
      const raw =
        typeof value === "object" ? JSON.stringify(value) : String(value ?? "");
      return `"${(/^[=+@\-]/.test(raw) ? "'" + raw : raw).replaceAll('"', '""')}"`;
    };
    const csv = [
      keys,
      ...report.rows.map((row: Json) => keys.map((key) => row[key])),
    ]
      .map((row) => row.map(safeCell).join(","))
      .join("\r\n");
    const url = URL.createObjectURL(
      new Blob(["\ufeff" + csv], { type: "text/csv;charset=utf-8" }),
    );
    const link = document.createElement("a");
    link.href = url;
    link.download = `${report.name}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }
  function printDocument() {
    if (window.motorlineNative) void window.motorlineNative.print().catch(fail);
    else window.print();
  }
  function productLabel(product: Json): LabelItem {
    return {
      name: product.name,
      code: product.barcodes?.[0] || product.sku,
      sku: product.sku,
      price: product.type === "service" ? undefined : product.retailPrice,
    };
  }
  function printLabels(items: LabelItem[], title = "Print labels") {
    if (!items.length) {
      toast("Nothing to print.");
      return;
    }
    setError("");
    setModal({
      title,
      wide: items.length > 1,
      content: <LabelSheet items={items} money={money} print={printDocument} />,
    });
  }
  function printLabel(product: Json) {
    if (product.id && !product.barcodes?.length)
      toast("This part has no barcode, so its SKU is printed. Edit the part to add or create a barcode.");
    printLabels([productLabel(product)], `Label · ${product.name}`);
  }

  async function login(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const data = Object.fromEntries(
        new FormData(event.currentTarget),
      ) as Record<string, string>;
      const address = data.api.trim().replace(/\/$/, "");
      const auth = await request(
        { api: address, token: "" } as Session,
        "/auth/login",
        {
          email: data.email,
          password: data.password,
          branchId: data.branchId,
          organizationId: data.organizationId,
        },
      );
      const active = { ...auth, api: address } as Session;
      const savedConnection = {api:address, organizationId:data.organizationId, branchId:data.branchId};
      await writeLocal("connection-profile", savedConnection);
      setConnection(savedConnection);
      const nextSnapshot = await request(active, "/bootstrap");
      const previous = await readLocal<Workspace>(scopeKey(active));
      const enrollment = await readLocal<Json>(deviceKey(active));
      const saved = {
        snapshot: nextSnapshot,
        pending: previous?.pending || [],
        device: enrollment?.device || previous?.device || null,
        nextInvoice: enrollment?.nextInvoice || previous?.nextInvoice || 0,
        lastSync: new Date().toISOString(),
        cart: previous?.cart,
      };
      await writeLocal(scopeKey(active), saved);
      await writeLocal("active-session", active);
      setSession(active);
      setWorkspace(saved);
      setCart(previous?.cart || emptyCart());
      setOnline(true);
    } catch (reason) {
      fail(reason);
    } finally {
      setBusy(false);
    }
  }

  if (!ready) return <div className="loading">Opening your register…</div>;
  if (!session || !workspace || !cart)
    return (
      <main className="login-screen">
        <div className="login-brand">
          <div className="brand-mark">
            <i />
            <i />
            <i />
          </div>
          <h1>
            Motorline<span>.</span>
          </h1>
          <p>Parts. People. Every transaction.</p>
        </div>
        <form className="login-card" onSubmit={login}>
          <h2>Open your workspace</h2>
          <p>Sign in to your shop server.</p>
          <FieldInput
            field={{
              name: "api",
              label: "Server API",
              value: connection.api || "",
              type: "url",
              required: true,
            }}
          />
          <FieldInput
            field={{
              name: "organizationId",
              label: "Organization code",
              value: connection.organizationId || "",
              required: true,
            }}
          />
          <FieldInput
            field={{
              name: "email",
              label: "Email",
              type: "email",
              required: true,
            }}
          />
          <FieldInput
            field={{
              name: "password",
              label: "Password",
              type: "password",
              required: true,
            }}
          />
          <FieldInput
            field={{
              name: "branchId",
              label: "Branch code",
              value: connection.branchId || "",
              required: true,
            }}
          />
          {error && (
            <p className="form-error" role="alert">
              {error}
            </p>
          )}
          <button className="primary-button" disabled={busy}>
            Sign in
          </button>
        </form>
      </main>
    );

  let billError = "";
  let bill: ReturnType<typeof quote>;
  try {
    bill = quote(cart, products, snapshot.settings?.roundingIncrement || 1, snapshot.settings?.taxMode || "exclusive");
  } catch (reason) {
    billError = reason instanceof Error ? reason.message : String(reason);
    bill = quote({ ...cart, lines: [] }, products, 1, snapshot.settings?.taxMode || "exclusive");
  }
  const receiptMoney = (amount:number) => money(amount, receipt?.currency || snapshot.settings?.currency || "INR");
  const filtered = products.filter(
    (product) =>
      (category === "All parts" || product.category === category) &&
      (!search ||
        [
          product.name,
          product.sku,
          product.partNumber,
          product.description,
          ...(product.barcodes || []),
          ...(product.oemReferences || []),
          ...(product.supersedes || []),
        ].some((value) => normalize(value).includes(normalize(search)))) &&
      (!cart.vehicle ||
        ["compatible", "universal"].includes(
          fitment(product, cart.vehicle).status,
        )),
  );
  const cartNeedsApproval = cartNeedsApprovalFor(cart);
  return (
    <>
      <div className="app-shell">
        <aside className="sidebar">
          <div className="brand">
            <span className="brand-mark" aria-hidden="true">
              <i />
              <i />
              <i />
            </span>
            <div>
              <div className="brand-name">
                Motorline<span>.</span>
              </div>
              <div className="brand-label">
                {snapshot.settings?.business?.tradingName ||
                  snapshot.settings?.business?.legalName ||
                  "Automotive POS"}
              </div>
            </div>
          </div>
          <nav className="navigation" aria-label="Workspace">
            {navItems.map((item) => {
              const tabs = tabsFor(item.tabs, role, features);
              if (!tabs.length) return null;
              const active = tabs.some((tab) => tab.name === section);
              const attention =
                item.label === "Settings" &&
                (workspace.pending.length > 0 ||
                  (snapshot.conflicts || []).some((entry: Json) => entry.status === "pending"));
              return (
                <button
                  key={item.label}
                  className={`nav-link ${active ? "is-active" : ""}`}
                  aria-current={active ? "page" : undefined}
                  onClick={() => openSection(tabs[0].name)}
                >
                  <span className={`nav-icon ${item.icon}`} aria-hidden="true" />
                  <span>{item.label}</span>
                  {attention && <span className="nav-badge" aria-hidden="true" title="Sales waiting to sync" />}
                </button>
              );
            })}
          </nav>
          <div className="register-info">
            <div>
              <strong>{snapshot.branch?.name || session.branchId}</strong>
              <span className="register-label">
                {session.user.name || session.user.email} · {titleCase(role || "")}
              </span>
            </div>
          </div>
        </aside>
        <div className="main-shell">
          <header className="topbar">
            <div className="search-field">
              <span className="icon-search" />
              <input
                aria-label="Search parts, codes, or records"
                id="global-search"
                placeholder="Search parts or codes"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key !== "Enter" || section !== "Billing" || !search.trim()) return;
                  event.preventDefault();
                  handleScan(search);
                }}
              />
              <kbd>Enter</kbd>
            </div>
            <div className="sync-status">
              <span className={online ? "status-dot" : "status-dot offline"} />
              {online ? "Server connected" : "Offline · stock snapshot"}
              <small>
                {workspace.pending.length} pending ·{" "}
                {workspace.lastSync
                  ? new Date(workspace.lastSync).toLocaleTimeString()
                  : "Never synced"}
              </small>
            </div>
            {canSell && <button
              className="button"
              onClick={() =>
                setModal({
                  title: "Parked sales",
                  content: (
                    <div className="dialog-options">
                      {!(snapshot.holds || []).length && (
                        <p>No parked sales. Use Hold on the current sale to park it and reserve its stock.</p>
                      )}
                      {(snapshot.holds || []).map((hold: Json) => (
                        <div className="parked-row" key={hold.id}>
                          <button
                            type="button"
                            className="dialog-option"
                            onClick={() => {
                              if (cart.lines.length) {
                                setError(
                                  "Hold or clear the current sale first.",
                                );
                                return;
                              }
                              setCart({ ...hold.cart, holdId: hold.id });
                              setSection("Billing");
                              setModal(null);
                            }}
                          >
                            <strong>
                              {(snapshot.customers || []).find(
                                (customer: Json) =>
                                  customer.id === hold.cart?.customerId,
                              )?.name || "Walk-in customer"}
                            </strong>
                            <small>
                              {(hold.cart?.lines || [])
                                .map(
                                  (line: Json) =>
                                    `${line.qty} × ${productName(line.productId)}`,
                                )
                                .join(", ")}
                            </small>
                            <small>
                              Parked {formatDate(hold.createdAt)} by{" "}
                              {userName(hold.userId)}
                            </small>
                          </button>
                          <button
                            type="button"
                            className="button"
                            onClick={async () => {
                              try {
                                await api(
                                  `/holds/${hold.id}`,
                                  undefined,
                                  "DELETE",
                                );
                                await refresh("Reservation released.");
                                setModal(null);
                              } catch (reason) {
                                fail(reason);
                              }
                            }}
                          >
                            Discard
                          </button>
                        </div>
                      ))}
                    </div>
                  ),
                })
              }
            >
              Parked ({(snapshot.holds || []).length})
            </button>}
            {(window.motorlineNative?.platform === "android" || cameraScan) && (
              <button
                className="button"
                onClick={() => void scanWithDevice()}
                title="Scan a barcode with the camera"
              >
                Scan
              </button>
            )}
          </header>
          <main id="workspace">
            <div className="workspace-heading">
              <h1>{section === "Billing" ? "Sales terminal" : currentNav?.label || section}</h1>
              <p>{sectionHelp[section] || snapshot.branch?.name}</p>
            </div>
            {currentTabs.length > 1 && (
              <div className="section-tabs" role="tablist" aria-label={`${currentNav?.label} views`}>
                {currentTabs.map((tab) => (
                  <button
                    key={tab.name}
                    role="tab"
                    aria-selected={tab.name === section}
                    className={`section-tab ${tab.name === section ? "is-active" : ""}`}
                    onClick={() => openSection(tab.name)}
                  >
                    {tab.label}
                  </button>
                ))}
              </div>
            )}
            {error && (
              <div className="error-banner" role="alert">
                {error}
                <button aria-label="Dismiss error" onClick={() => setError("")}>
                  ×
                </button>
              </div>
            )}
            {section === "Billing" ? (
              <div className="billing-layout">
                <section className="catalog-panel">
                  {features.fitment && <button className="vehicle-picker" onClick={chooseVehicle}>
                    <span className="vehicle-icon">
                      <span className="icon-car" />
                    </span>
                    <span className="vehicle-context">
                      <span className="vehicle-caption">Vehicle fitment</span>
                      <strong>
                        {cart.vehicle
                          ? `${cart.vehicle.year} ${cart.vehicle.make} ${cart.vehicle.model}`
                          : "All vehicles"}
                      </strong>
                    </span>
                    <span className="vehicle-detail">
                      {cart.vehicle
                        ? [cart.vehicle.engine, cart.vehicle.fuel]
                            .filter(Boolean)
                            .join(" · ")
                        : "Optional · choose one to check compatibility"}
                    </span>
                  </button>}
                  <div className="catalog-heading">
                    <h2>Parts catalog</h2>
                    <span className="catalog-count">
                      {filtered.length} results
                    </span>
                  </div>
                  <div className="categories">
                    {[
                      "All parts",
                      ...new Set(products.map((product) => product.category)),
                    ].map((value) => (
                      <button
                        key={value}
                        className={`category-pill ${category === value ? "is-active" : ""}`}
                        onClick={() => setCategory(value)}
                      >
                        {value}
                      </button>
                    ))}
                  </div>
                  <div className="part-grid">
                    {filtered.map((product) => (
                      <article className="part-card" key={product.id}>
                        <div className="part-media">
                          {product.icon ? (
                            <img src={`/assets/${product.icon}.jpg`} alt="" />
                          ) : (
                            <span className="part-placeholder">▤</span>
                          )}
                          <span
                            className={`part-stock ${available(product.id) <= product.reorderLevel ? "is-low" : ""}`}
                          >
                            {product.type === "service"
                              ? "Service"
                              : available(product.id) > 0
                                ? `${available(product.id)} available`
                                : "Out of stock"}
                          </span>
                        </div>
                        <div className="part-info">
                          <div className="part-category">
                            {product.brand} · {product.sku}
                          </div>
                          <h3>{product.name}</h3>
                          <div
                            className={`part-fitment fit-${fitment(product, cart.vehicle).status}`}
                          >
                            {cart.vehicle
                              ? `${titleCase(fitment(product, cart.vehicle).status)}${product.partNumber ? " · " : ""}`
                              : ""}
                            {product.partNumber}
                          </div>
                          <small className="bin-hint">
                            {stock
                              .filter(
                                (item) =>
                                  item.productId === product.id &&
                                  item.available > 0 &&
                                  bins.some(
                                    (bin) =>
                                      bin.id === item.binId &&
                                      bin.kind === "sellable",
                                  ),
                              )
                              .map(
                                (item) =>
                                  `${locationName(item.binId)} (${item.available})`,
                              )
                              .join(" · ") || "Check stock"}
                          </small>
                          <div className="part-footer">
                            <strong className="part-price">
                              {money(
                                cart.priceLevel === "retail"
                                  ? product.retailPrice
                                  : product.wholesalePrice,
                              )}
                            </strong>
                            <button
                              className="part-add"
                              aria-label={`Add ${product.name}`}
                              onClick={() => addPart(product)}
                            >
                              +
                            </button>
                          </div>
                          {product.interchanges?.length > 0 && (
                            <small>
                              Interchange · {product.interchanges.join(", ")}
                            </small>
                          )}
                        </div>
                      </article>
                    ))}
                  </div>
                </section>
                <aside className="checkout-panel">
                  <div className="checkout-heading">
                    <h2>Current sale</h2>
                    <button
                      className="text-button"
                      onClick={() => {
                        if (confirm("Clear this draft sale?"))
                          setCart(emptyCart());
                      }}
                    >
                      Clear
                    </button>
                  </div>
                  <label className="field customer-field">
                    <span>
                      Customer
                      <button
                        type="button"
                        className="text-button"
                        onClick={() =>
                          addContact("customers", {}, (saved) =>
                            updateCart({ customerId: saved.id }),
                          )
                        }
                      >
                        + New
                      </button>
                    </span>
                    <select
                      value={cart.customerId}
                      onChange={(event) =>
                        updateCart({ customerId: event.target.value })
                      }
                    >
                      <option value="">Walk-in customer</option>
                      {(snapshot.customers || []).map((customer: Json) => (
                        <option key={customer.id} value={customer.id}>
                          {customer.name}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label className="field">
                    <span>Price level</span>
                    <select
                      value={cart.priceLevel}
                      onChange={(event) =>
                        updateCart({ priceLevel: event.target.value })
                      }
                    >
                      <option value="retail">Retail</option>
                      <option value="wholesale">Wholesale</option>
                    </select>
                  </label>
                  <div className="cart-lines">
                    {bill.lines.length ? (
                      bill.lines.map((line: Json, index: number) => (
                        <div
                          className="cart-line"
                          key={`${line.productId}-${index}`}
                        >
                          <div className="line-description">
                            <strong>{line.product.name}</strong>
                            <small>
                              {money(line.unitPrice)} each
                              {line.binId ? ` · ${locationName(line.binId)}` : ""}
                            </small>
                            {cart.vehicle && (
                              <small
                                className={`fit-${fitment(line.product, cart.vehicle).status}`}
                              >
                                {titleCase(fitment(line.product, cart.vehicle).status)}
                                {line.overrideReason
                                  ? " · override recorded"
                                  : ""}
                              </small>
                            )}
                            {line.serials?.length > 0 && (
                              <small>Serials {line.serials.join(", ")}</small>
                            )}
                            <div className="qty-stepper" aria-label={`Quantity of ${line.product.name}`}>
                              <button
                                type="button"
                                aria-label="Decrease quantity"
                                disabled={line.product.serialTracked}
                                onClick={() => setLineQuantity(index, line.qty - 1)}
                              >
                                −
                              </button>
                              <span>{line.qty}</span>
                              <button
                                type="button"
                                aria-label="Increase quantity"
                                disabled={line.product.serialTracked}
                                onClick={() => setLineQuantity(index, line.qty + 1)}
                              >
                                +
                              </button>
                            </div>
                          </div>
                          <button
                            className="line-remove"
                            aria-label={`Remove ${line.product.name}`}
                            onClick={() =>
                              updateCart({
                                lines: cart.lines.filter(
                                  (_: Json, i: number) => i !== index,
                                ),
                              })
                            }
                          >
                            ×
                          </button>
                          <strong className="line-price">
                            {money(line.total)}
                          </strong>
                        </div>
                      ))
                    ) : (
                      <div className="empty-state">
                        <span className="empty-symbol">▤</span>
                        <strong>No items in this sale</strong>
                        <p>Add a part or service to start the bill.</p>
                      </div>
                    )}
                  </div>
                  {billError && (
                    <p className="form-error cart-error" role="alert">
                      {billError} Clear the sale or refresh the catalog.
                    </p>
                  )}
                  {cartNeedsApproval && (
                    <button
                      className="button approval-button"
                      onClick={approveCart}
                    >
                      Review fitment approval
                    </button>
                  )}
                  <div className="checkout-summary">
                    <dl className="totals">
                      <div>
                        <dt>Subtotal{bill.taxMode === "inclusive" ? " (includes tax)" : ""}</dt>
                        <dd>{money(bill.subtotal)}</dd>
                      </div>
                      <div>
                        <dt>{snapshot.settings?.taxDisplayName || "Tax"}{bill.taxMode === "inclusive" ? " included" : ""}</dt>
                        <dd>{money(bill.tax)}</dd>
                      </div>
                      <div>
                        <dt>Core charges</dt>
                        <dd>{money(bill.core)}</dd>
                      </div>
                      <div>
                        <dt>
                          <button
                            className="text-button"
                            onClick={() =>
                              form(
                                "Sale discount",
                                [
                                  {
                                    name: "discount",
                                    label: `Discount amount (subtotal ${money(bill.subtotal)})`,
                                    type: "number",
                                    min: 0,
                                    step: "0.01",
                                    value: ((cart.discount || 0) / 100).toFixed(2),
                                    required: true,
                                    help: "Enter 0 to remove the discount.",
                                  },
                                  { ...reasonField, value: cart.discountReason, required: false },
                                  ...(!manager
                                    ? [
                                        {
                                          name: "approvalId",
                                          label: "Manager approval ID",
                                          required: false,
                                          help: `Required above ${money(snapshot.settings.cashierDiscountLimit || 0)}. Approval transaction ${cart.transactionId}`,
                                        },
                                      ]
                                    : []),
                                ],
                                async (data) => {
                                  const requested = Math.round(Number(data.discount) * 100);
                                  if (!Number.isFinite(requested) || requested < 0) throw new Error("Enter a valid discount amount.");
                                  if (requested > bill.subtotal) throw new Error(`Discount cannot exceed the subtotal of ${money(bill.subtotal)}.`);
                                  if (requested === 0) {
                                    updateCart({ discount: 0, discountReason: "", discountApprovalId: undefined });
                                    return;
                                  }
                                  if (!String(data.reason || "").trim()) throw new Error("Enter a reason for the discount.");
                                  if (!manager && requested > (snapshot.settings.cashierDiscountLimit || 0) && !data.approvalId) throw new Error("Manager approval is required above your discount limit.");
                                  const id = manager
                                    ? await approval(
                                        "discount",
                                        cart.transactionId,
                                        data.reason,
                                      )
                                    : data.approvalId;
                                  updateCart({
                                    discount: Math.round(
                                      Number(data.discount) * 100,
                                    ),
                                    discountReason: data.reason,
                                    discountApprovalId: id,
                                  });
                                },
                              )
                            }
                          >
                            Discount
                          </button>
                        </dt>
                        <dd>{bill.discount ? `−${money(bill.discount)}` : money(0)}</dd>
                      </div>
                      {bill.rounding !== 0 && (
                        <div>
                          <dt>Rounding</dt>
                          <dd>{money(bill.rounding)}</dd>
                        </div>
                      )}
                      <div className="grand-total">
                        <dt>Total payable</dt>
                        <dd>{money(bill.total)}</dd>
                      </div>
                    </dl>
                    <div className="checkout-actions">
                      <button
                        className="button"
                        disabled={!online || !cart.lines.length}
                        onClick={() => holdSale().catch(fail)}
                      >
                        Hold
                      </button>
                      <button
                        className="primary-button"
                        disabled={!cart.lines.length || cartNeedsApproval || !!billError}
                        onClick={showCheckout}
                        title="F6"
                      >
                        Checkout ↗
                      </button>
                    </div>
                    {!manager && (
                      <small className="transaction-reference">
                        Approval reference {cart.transactionId}
                      </small>
                    )}
                  </div>
                </aside>
              </div>
            ) : (
              <section className="data-panel">{viewForSection()}</section>
            )}
          </main>
        </div>
      </div>
      <dialog
        ref={dialogRef}
        className={`dialog ${modal?.wide || (modal?.fields && modal.fields.filter((field) => !field.advanced).length > 6) ? "wide-dialog" : ""}`}
        onCancel={() => {
          setModal(null);
          setReceipt(null);
          setError("");
        }}
      >
        <button
          className="dialog-close"
          aria-label="Close dialog"
          onClick={() => {
            setModal(null);
            setReceipt(null);
            setError("");
          }}
        >
          ×
        </button>
        {receipt ? (
          <div className="receipt">
            <p className="receipt-kind">
              {receipt.invoiceId
                ? receipt.voided ? "Credit note · invoice void" : "Credit note"
                : receipt.taxScheme === "india-gst" ? "Tax invoice" : "Sales receipt"}
            </p>
            <h2>{receipt.number || receipt.id}</h2>
            <h3>{receipt.business?.legalName || receipt.business?.tradingName || snapshot.organization?.name || receipt.branch?.name || snapshot.branch?.name}</h3>
            {receipt.invoiceNumber && receipt.invoiceId && (
              <p>Against invoice {receipt.invoiceNumber}{receipt.invoiceDate ? ` dated ${formatDate(receipt.invoiceDate)}` : ""}</p>
            )}
            {receipt.id && !receipt.invoiceId && invoiceStatus(receipt) !== "Finalized" && (
              <p className="receipt-flag">{invoiceStatus(receipt)}</p>
            )}
            {receipt.business?.tradingName && receipt.business.tradingName !== receipt.business.legalName && <p>{receipt.business.tradingName}</p>}
            {receipt.business?.address && <p className="receipt-address">{receipt.business.address}</p>}
            {receipt.business?.taxRegistrationId && <p>Tax registration: {receipt.business.taxRegistrationId}</p>}
            <p>{receipt.branch?.name || receipt.branchId}{receipt.branch?.address ? ` · ${receipt.branch.address}` : ""}</p>
            {(receipt.business?.phone || receipt.business?.email) && <p>{[receipt.business.phone,receipt.business.email].filter(Boolean).join(" · ")}</p>}
            {receipt.customer && <div className="receipt-customer"><strong>Customer: {receipt.customer.name}</strong>
              {receipt.customer.address && <p className="receipt-address">{receipt.customer.address}</p>}
              {receipt.customer.taxRegistrationId && <p>Tax registration: {receipt.customer.taxRegistrationId}</p>}
            </div>}
            {receipt.placeOfSupply && <p>Place of supply: {receipt.placeOfSupply}</p>}
            <p>
              {formatDate(receipt.createdAt || receipt.occurredAt)} ·{" "}
              {receipt.status || (receipt.invoiceId ? `Refund · ${receipt.refundType || "Cash"}` : "Finalized")}
              {(receipt.cashierId || receipt.userId) ? ` · ${userName(receipt.cashierId || receipt.userId)}` : ""}
            </p>
            {receipt.reason && receipt.invoiceId && <p>Reason: {receipt.reason}</p>}
            <DataTable
              rows={receipt.lines || []}
              columns={[
                [
                  "Item",
                  (line) =>
                    line.name ||
                    line.product?.name ||
                    productName(line.productId),
                ],
                ["HSN / SAC", (line) => line.hsnSac || line.product?.hsnSac || "—"],
                ["Qty", (line) => `${line.qty ?? line.quantity} ${line.unit || line.product?.unit || ""}`],
                ["Tax %", (line) => (line.taxRate ?? line.product?.taxRate ?? 0) / 100],
                ["Taxable", (line) => receiptMoney((line.subtotal || 0) - (line.discount || 0) - (receipt.taxMode === "inclusive" ? line.tax || 0 : 0))],
                ["Total", (line) => receiptMoney(line.total)],
              ]}
            />
            <dl className="receipt-totals">
              {receipt.subtotal !== undefined && (
                <div>
                  <dt>Subtotal</dt>
                  <dd>{receiptMoney(receipt.subtotal)}</dd>
                </div>
              )}
              {!!receipt.discount && (
                <div>
                  <dt>Discount{receipt.discountReason ? ` · ${receipt.discountReason}` : ""}</dt>
                  <dd>−{receiptMoney(receipt.discount)}</dd>
                </div>
              )}
              {(receipt.taxComponents || []).map((component:Json)=><div key={component.name}><dt>{component.name}</dt><dd>{receiptMoney(component.amount)}</dd></div>)}
              <div>
                <dt>{receipt.taxDisplayName || "Tax"}{receipt.taxMode === "inclusive" ? " included" : ""}</dt>
                <dd>{receiptMoney(receipt.tax)}</dd>
              </div>
              {!!(receipt.core || receipt.coreTotal) && (
                <div>
                  <dt>Refundable core charges</dt>
                  <dd>{receiptMoney(receipt.core || receipt.coreTotal)}</dd>
                </div>
              )}
              {!!receipt.rounding && (
                <div>
                  <dt>Rounding</dt>
                  <dd>{receiptMoney(receipt.rounding)}</dd>
                </div>
              )}
              <div className="grand-total">
                <dt>{receipt.invoiceId ? "Total refunded" : "Total"}</dt>
                <dd>{receiptMoney(receipt.total)}</dd>
              </div>
              {(receipt.tenders || []).map((tender: Json, index: number) => (
                <div key={index}>
                  <dt>
                    Paid · {tender.type}
                    {tender.reference ? ` · ${tender.reference}` : ""}
                    {tender.type !== "Cash" && !tender.confirmed ? " · awaiting confirmation" : ""}
                  </dt>
                  <dd>{receiptMoney(tender.amount)}</dd>
                </div>
              ))}
              {receipt.change !== undefined && (
                <div>
                  <dt>Change</dt>
                  <dd>{receiptMoney(receipt.change)}</dd>
                </div>
              )}
            </dl>
            {receipt.receiptFooter && <p className="receipt-address">{receipt.receiptFooter}</p>}
            <div className="dialog-actions">
              <button
                className="button"
                onClick={() =>
                  window.motorlineNative
                    ? window.motorlineNative.print()
                    : window.print()
                }
              >
                Print / Save PDF
              </button>
              <button
                className="primary-button"
                onClick={() => {
                  setReceipt(null);
                  setModal(null);
                }}
              >
                Done
              </button>
            </div>
          </div>
        ) : (
          modal && (
            <>
              <h2>{modal.title}</h2>
              <form
                onInvalidCapture={(event) => {
                  const details = (event.target as HTMLElement).closest("details");
                  if (details) details.open = true;
                }}
                onSubmit={async (event) => {
                  event.preventDefault();
                  if (!modal.action) return;
                  setBusy(true);
                  setError("");
                  try {
                    const entries = new FormData(event.currentTarget);
                    const data: Json = Object.fromEntries(entries);
                    for (const field of modal.fields || [])
                      if (field.type === "checks")
                        data[field.name] = entries.getAll(field.name).map(String);
                    await modal.action(data);
                    setModal(null);
                  } catch (reason) {
                    fail(reason);
                  } finally {
                    setBusy(false);
                  }
                }}
              >
                {modal.content}
                {(() => {
                  const basic = (modal.fields || []).filter((field) => !field.advanced);
                  const more = (modal.fields || []).filter((field) => field.advanced);
                  const grid = (count: number) => (count > 6 ? "editor-grid" : "");
                  return (
                    <>
                      <div className={grid(basic.length)}>
                        {basic.map((field) => (
                          <FieldInput key={field.name} field={field} />
                        ))}
                      </div>
                      {more.length > 0 && (
                        <details className="more-options" open={modal.expanded}>
                          <summary>More options ({more.length})</summary>
                          <div className={grid(more.length)}>
                            {more.map((field) => (
                              <FieldInput key={field.name} field={field} />
                            ))}
                          </div>
                        </details>
                      )}
                    </>
                  );
                })()}
                {error && (
                  <p className="form-error" role="alert">
                    {error}
                  </p>
                )}
                {modal.action && (
                  <div className="dialog-actions">
                    <button
                      type="button"
                      className="button"
                      onClick={() => setModal(null)}
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      className="primary-button"
                      disabled={busy}
                    >
                      {busy ? "Saving…" : modal.submit || "Save"}
                    </button>
                  </div>
                )}
              </form>
            </>
          )
        )}
      </dialog>
      {notice && (
        <div className="toast" role="status">
          {notice}
        </div>
      )}
    </>
  );
}
