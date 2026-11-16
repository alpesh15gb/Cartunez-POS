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
  type Json,
  type Session,
  type Workspace,
} from "./storage";
import JsBarcode from "jsbarcode";

const sections = [
  "Billing",
  "Inventory",
  "Locations",
  "Purchasing",
  "Customers",
  "Suppliers",
  "Sales history",
  "Dashboard",
  "Transfers",
  "Fitment",
  "Shifts",
  "Reconciliation",
  "Warranty & cores",
  "Reports",
  "Settings",
];
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
};
type Modal = {
  title: string;
  fields?: Field[];
  content?: React.ReactNode;
  submit?: string;
  action?: (data: Json) => Promise<void>;
  wide?: boolean;
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
        <input
          name={field.name}
          type={field.type || "text"}
          defaultValue={field.value ?? ""}
          required={field.required}
          min={field.min}
          step={field.step || (field.type === "number" ? "1" : undefined)}
        />
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

function Barcode({ value }: { value: string }) {
  const element = useRef<SVGSVGElement>(null);
  useEffect(() => {
    if (element.current)
      JsBarcode(element.current, value, {
        format: "CODE128",
        height: 55,
        width: 1.5,
        fontSize: 13,
        margin: 8,
      });
  }, [value]);
  return <svg ref={element} aria-label={`Barcode ${value}`} />;
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
  const snapshot = workspace?.snapshot || {};
  const products: Json[] = snapshot.products || [];
  const bins: Json[] = snapshot.locations || [];
  const stock: Json[] = snapshot.stock || [];
  const role = session?.user.role;
  const manager = role === "owner" || role === "manager";
  const inventoryRole = manager || role === "inventory";
  const money = (amount: number, currency = snapshot.settings?.currency || "INR") =>
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
  ) {
    setError("");
    setModal({ title, fields, action, submit });
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
  function addPart(product: Json) {
    if (!cart) return;
    const result = fitment(product, cart.vehicle);
    const choices = bins.filter(
      (bin) => bin.kind === "sellable" && available(product.id, bin.id) > 0,
    );
    const fields: Field[] = [
      quantityField("qty"),
      {
        name: "binId",
        label: "Confirm the bin picked",
        options: options(
          choices,
          (bin) =>
            `${binName(bin)} · ${available(product.id, bin.id)} available`,
        ),
        value: choices[0]?.id,
        required: product.type !== "service" && product.category !== "Services",
      },
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
        label: `${result.status} fitment — approval reason`,
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
      });
    form(
      `Add ${product.name}`,
      fields,
      async (data) => {
        const qty = Number(data.qty);
        const existing = cart.lines.find(
          (line: Json) =>
            line.productId === product.id && line.binId === data.binId,
        );
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
          help:
            name === "engine"
              ? "Complete qualifiers when a part requires them."
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
    if (!cart?.lines.length) return;
    const bill = quote(
      cart,
      products,
      snapshot.settings?.roundingIncrement || 1,
      snapshot.settings?.taxMode || "exclusive",
    );
    const shifts = (snapshot.shifts || []).filter(
      (shift: Json) =>
        !shift.closedAt && (!shift.userId || shift.userId === session?.user.id),
    );
    if (!shifts.length) {
      openShift();
      return;
    }
    if (!cart.shiftId && shifts.length) updateCart({ shiftId: shifts[0].id });
    const tenderOptions = (snapshot.settings?.tenderTypes || ["Cash", "Card", "UPI"]).map((type: string) => ({
      value: type,
      label: type,
    }));
    form(
      `Checkout · ${money(bill.total)}`,
      [
        {
          name: "tender",
          label: "Payment type",
          options: tenderOptions,
          value: "Cash",
          required: true,
        },
        {
          name: "amount",
          label: "Amount received",
          type: "number",
          value: (bill.total / 100).toFixed(2),
          step: "0.01",
          min: 0,
          required: true,
        },
        { name: "secondTender", label: "Split tender", options: tenderOptions },
        {
          name: "secondAmount",
          label: "Split amount",
          type: "number",
          value: 0,
          min: 0,
          step: "0.01",
        },
        {
          name: "confirmed",
          label: "Card / UPI provider confirmation",
          options: [
            { value: "no", label: "Awaiting confirmation" },
            { value: "yes", label: "Confirmed by provider" },
          ],
          value: "no",
        },
        { name: "reference", label: "Provider reference" },
        {name:"placeOfSupply",label:snapshot.settings?.taxScheme === "india-gst" ? "Place of supply state code" : "Place of supply",value:(snapshot.customers || []).find((customer:Json)=>customer.id === cart.customerId)?.stateCode || snapshot.settings?.business?.stateCode || "",required:snapshot.settings?.taxScheme === "india-gst",help:snapshot.settings?.taxScheme === "india-gst" ? "Confirm the two-digit state code for this supply." : undefined},
      ],
      checkout,
      online ? "Complete sale" : "Save offline sale",
    );
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
    form("Register settings", [
      {name:"currency", label:"Currency code", value:settings.currency, required:true, help:"Use a currency with two decimal minor units, such as INR, USD or EUR."},
      {name:"invoicePrefix", label:"Invoice prefix", value:settings.invoicePrefix, required:true},
      {name:"nextInvoice", label:"Next online invoice number", type:"number", min:1, value:settings.nextInvoice, required:true, help:"Numbers can only move forward. Reserved offline ranges are skipped."},
      {name:"taxDisplayName", label:"Tax label on receipts", value:settings.taxDisplayName || "Tax", required:true},
      {name:"taxScheme", label:"Tax scheme", options:[{value:"general",label:"General tax"},{value:"india-gst",label:"India GST — ordinary domestic sales"}], value:settings.taxScheme || "general", required:true,help:"GST requires the registered business state, GSTIN and part HSN/SAC. Special supplies and electronic government filing need separate integrations."},
      {name:"localTaxName", label:"Local GST component", options:[{value:"SGST",label:"SGST"},{value:"UTGST",label:"UTGST"}], value:settings.localTaxName || "SGST", required:true},
      {name:"creditNotePrefix", label:"Credit note prefix", value:settings.creditNotePrefix || "CR", required:true},
      {name:"taxMode", label:"Catalog pricing", options:[{value:"exclusive",label:"Prices exclude tax"},{value:"inclusive",label:"Prices include tax"}], value:settings.taxMode || "exclusive", required:true},
      {name:"taxRates", label:"Tax rates in percent, comma separated", value:(settings.taxRates || []).map((rate:number)=>rate/100).join(", "), required:true},
      {name:"tenderTypes", label:"Enabled payment types", value:(settings.tenderTypes || ["Cash","Card","UPI"]).join(", "), required:true, help:"Cash, Card, UPI. Card and UPI require an externally confirmed payment reference."},
      {name:"offlineTenders", label:"Offline payment types", value:(settings.offlineTenders || []).join(", "), help:"Cash only. Leave empty to disable offline payments."},
      ...[["sessionHours","Session hours",1],["offlineHours","Maximum offline hours",0],["roundingIncrement","Rounding increment in minor units",1],["cashierDiscountLimit","Cashier discount limit in minor units",0]].map(([name,label,min])=>({name:String(name),label:String(label),type:"number",min:Number(min),value:settings[String(name)],required:true})),
    ], async data => {
      await mutate("/settings", {...data,
        nextInvoice:Number(data.nextInvoice), sessionHours:Number(data.sessionHours), offlineHours:Number(data.offlineHours),
        roundingIncrement:Number(data.roundingIncrement),cashierDiscountLimit:Number(data.cashierDiscountLimit),
        taxRates:list(data.taxRates).map(rate=>Math.round(Number(rate)*100)),
        tenderTypes:list(data.tenderTypes), offlineTenders:list(data.offlineTenders),
      }, "Register settings updated. Review catalog prices when changing the tax mode.");
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
  function editProduct(product: Json = {}) {
    const fields: Field[] = [
      ...[
        ["name", "Part name"],
        ["sku", "SKU"],
        ["brand", "Brand"],
        ["partNumber", "Manufacturer part number"],
        ["description", "Description"],
        ["category", "Category"],
        ["unit", "Unit"],
      ].map(([name, label]) => ({
        name,
        label,
        value: product[name] || (name === "unit" ? "Each" : ""),
        required: ["name", "sku", "brand", "category"].includes(name),
      })),
      ...[
        ["barcodes", "Barcodes"],
        ["oemReferences", "OEM references"],
        ["supplierReferences", "Supplier part references"],
        ["alternatives", "Alternative SKU IDs"],
        ["supersedes", "Superseded part numbers"],
        ["interchanges", "Interchange references"],
      ].map(([name, label]) => ({
        name,
        label,
        value: (product[name] || []).join(", "),
        help: "Comma separated",
      })),
      {
        name: "supplierId",
        label: "Supplier",
        options: options(snapshot.suppliers || []),
        value: product.supplierId,
      },
      ...[
        ["cost", "Cost"],
        ["retailPrice", "Retail price"],
        ["wholesalePrice", "Wholesale price"],
        ["coreCharge", "Refundable core charge"],
      ].map(([name, label]) => ({
        name,
        label,
        type: "number",
        min: 0,
        step: "0.01",
        value: (product[name] || 0) / 100,
        required: true,
      })),
      {
        name: "taxRate",
        label: "Tax rate (%)",
        type: "number",
        value: (product.taxRate ?? snapshot.settings?.taxRates?.[0] ?? 0) / 100,
        step: "0.01",
        min: 0,
        required: true,
      },
      {
        name: "taxCategory",
        label: "Tax category",
        value: product.taxCategory || "Standard",
        required: true,
      },
      {name: "hsnSac", label: "HSN / SAC", value: product.hsnSac || ""},
      {
        name: "packSize",
        label: "Pack size",
        type: "number",
        min: 1,
        value: product.packSize || 1,
        required: true,
      },
      {
        name: "reorderLevel",
        label: "Reorder level",
        type: "number",
        min: 0,
        value: product.reorderLevel ?? 0,
      },
      {
        name: "universal",
        label: "Universal fit",
        options: [
          { value: "true", label: "Universal" },
          { value: "false", label: "Vehicle dependent" },
        ],
        value: String(product.universal || false),
      },
      {
        name: "serialTracked",
        label: "Serial tracking",
        options: [
          { value: "true", label: "Required" },
          { value: "false", label: "Disabled" },
        ],
        value: String(product.serialTracked || false),
      },
    ];
    form(product.id ? "Edit part" : "Add part", fields, async (data) => {
      const values: Json = {
        ...product,
        ...data,
        universal: data.universal === "true",
        serialTracked: data.serialTracked === "true",
        packSize: Number(data.packSize),
        reorderLevel: Number(data.reorderLevel),
        taxRate: Math.round(Number(data.taxRate) * 100),
      };
      for (const key of ["cost", "retailPrice", "wholesalePrice", "coreCharge"])
        values[key] = Math.round(Number(data[key]) * 100);
      for (const key of [
        "barcodes",
        "oemReferences",
        "supplierReferences",
        "alternatives",
        "supersedes",
        "interchanges",
      ])
        values[key] = list(data[key]);
      await mutate("/products", values, "Part saved.");
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
      { name: "serials", label: "Serial numbers, comma separated" },
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
          options: (order.lines || []).map((line: Json) => ({
            value: line.productId,
            label: `${productName(line.productId)} · ordered ${line.quantity}`,
          })),
          required: true,
        },
        quantityField(),
        binField(),
        {
          name: "landedCost",
          label: "Additional landed cost for this receipt",
          type: "number",
          min: 0,
          step: "0.01",
          value: 0,
        },
        { name: "serials", label: "Serial numbers, comma separated" },
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
  function addContact(kind: string, contact: Json = {}) {
    form(
      `${contact.id ? "Edit" : "Add"} ${kind === "customers" ? "customer" : "supplier"}`,
      [
        { name: "name", label: "Name", value: contact.name, required: true },
        { name: "phone", label: "Phone", type: "tel", value: contact.phone },
        { name: "email", label: "Email", type: "email", value: contact.email },
        { name: "address", label: "Address", type: "textarea", value: contact.address },
        { name: "taxRegistrationId", label: "Tax registration / GSTIN", value: contact.taxRegistrationId },
        { name: "stateCode", label: "State code", value: contact.stateCode },
      ],
      async (data) => {
        await mutate(`/${kind}`, {...contact, ...data}, "Contact saved.");
      },
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
          required: true,
        },
        { name: "effectiveTo", label: "Effective until", type: "date" },
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
    form(
      `Return from ${invoice.number}`,
      [
        {
          name: "lineId",
          label: "Original invoice line",
          options: invoice.lines.map((line: Json) => ({
            value: line.id,
            label: `${line.name || line.product?.name || productName(line.productId)} · sold ${line.qty} · ${locationName(line.binId)}`,
          })),
          required: true,
        },
        quantityField(),
        {
          name: "condition",
          label: "Returned condition",
          options: ["sellable", "damaged", "warranty"].map((value) => ({
            value,
            label: value,
          })),
          value: "sellable",
        },
        binField("binId", "Return destination"),
        reasonField,
        {
          name: "refundType",
          label: "Refund method",
          options: ["Cash", "Card", "UPI"].map((value) => ({
            value,
            label: value,
          })),
          value: "Cash",
        },
        { name: "serials", label: "Returned serial numbers, comma separated" },
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
        binField(),
        quantityField(),
        { name: "serials", label: "Serial numbers, comma separated" },
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
        binField(),
        quantityField(),
        { name: "serials", label: "Serial numbers, comma separated" },
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
          name: "offlineHours",
          label: "Offline authorization hours",
          type: "number",
          min: 1,
          value: 24,
          required: true,
        },
        {
          name: "rangeSize",
          label: "Invoice range size",
          type: "number",
          min: 1,
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
          tenders: ["Cash"],
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
  function openShift() {
    form(
      "Open shift",
      [
        {
          name: "openingCash",
          label: "Opening cash",
          type: "number",
          step: "0.01",
          min: 0,
          value: 0,
          required: true,
        },
      ],
      async (data) => {
        const shift = await mutate(
          "/shifts/open",
          { openingCash: Math.round(Number(data.openingCash) * 100) },
          "Shift opened.",
        );
        updateCart({ shiftId: shift.id });
      },
    );
  }
  function closeShift(shift: Json) {
    form(
      "Close shift",
      [
        {
          name: "countedCash",
          label: "Cash counted",
          type: "number",
          min: 0,
          step: "0.01",
          required: true,
        },
        reasonField,
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
              ["Cost", (product) => money(product.cost)],
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
                  <button
                    className="button"
                    onClick={() => editFitment(product.id)}
                  >
                    Fitment
                  </button>
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
            rows={matching(snapshot.purchaseOrders || [])}
            columns={[
              ["Order", (order) => order.number || order.id],
              [
                "Supplier",
                (order) =>
                  snapshot.suppliers.find(
                    (supplier: Json) => supplier.id === order.supplierId,
                  )?.name,
              ],
              ["Status", (order) => order.status],
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
              inventoryRole && (
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
        <DataTable
          rows={matching(snapshot.invoices || [])}
          columns={[
            ["Invoice", (invoice) => invoice.number],
            ["Date", (invoice) => formatDate(invoice.createdAt)],
            ["Status", (invoice) => invoice.status || "Finalized"],
            ["Total", (invoice) => money(invoice.total)],
            ["Cashier", (invoice) => invoice.cashierId],
          ]}
          action={(invoice) => (
            <>
              <button className="button" onClick={() => setReceipt(invoice)}>
                Receipt
              </button>
              <button className="button" onClick={() => returnInvoice(invoice)}>
                Return
              </button>
              {manager && (
                <button
                  className="button"
                  onClick={() =>
                    form("Void invoice", [reasonField], async (data) => {
                      await mutate(
                        `/invoices/${invoice.id}/void`,
                        data,
                        "Audited invoice void recorded.",
                      );
                    })
                  }
                >
                  Void
                </button>
              )}
            </>
          )}
        />
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
              ["Transfer", (item) => item.number || item.id],
              ["From", (item) => item.branchId || item.sourceBranchId],
              ["To", (item) => item.destinationBranchId],
              ["Status", (item) => item.status],
            ]}
            action={(item) =>
              inventoryRole &&
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
            <button className="primary-button" onClick={openShift}>
              Open shift
            </button>
          </div>
          <DataTable
            rows={snapshot.shifts || []}
            columns={[
              ["Cashier", (shift) => shift.userId],
              [
                "Opened",
                (shift) => formatDate(shift.openedAt || shift.createdAt),
              ],
              ["Opening cash", (shift) => money(shift.openingCash)],
              ["Status", (shift) => (shift.closedAt ? "Closed" : "Open")],
              ["Variance", (shift) => money(shift.variance || 0)],
            ]}
            action={(shift) =>
              !shift.closedAt && (
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
            {manager && (
              <button className="primary-button" onClick={enrollDevice}>
                Enroll this counter
              </button>
            )}
            <button
              className="button"
              onClick={() => refresh("Synchronization checked.")}
            >
              Synchronize now
            </button>
          </div>
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
          <h2>Audit trail</h2>
          <DataTable
            rows={(snapshot.audit || []).slice(-100).reverse()}
            columns={[
              ["Time", (item) => formatDate(item.createdAt)],
              ["User", (item) => item.userId],
              ["Action", (item) => item.action],
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
                          (item: Json) => item.condition === "warranty",
                        ),
                      ),
                      required: true,
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
            <button
              className="button"
              onClick={() =>
                form(
                  "Record core return",
                  [
                    {
                      name: "invoiceId",
                      label: "Original invoice",
                      options: options(snapshot.invoices || []),
                      required: true,
                    },
                    partField(),
                    quantityField(),
                    reasonField,
                  ],
                  async (data) => {
                    await mutate(
                      "/core-returns",
                      {
                        ...data,
                        transactionId: crypto.randomUUID(),
                        quantity: Number(data.quantity),
                        refundType: "Cash",
                      },
                      "Core charge refund recorded.",
                    );
                  },
                )
              }
            >
              Receive core
            </button>
          </div>
          <h2>Warranty claims</h2>
          <DataTable
            rows={snapshot.warrantyClaims || []}
            columns={[
              ["Claim", (item) => item.id],
              ["Return", (item) => item.returnId],
              ["Status", (item) => item.status],
              ["Reason", (item) => item.reason],
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
              ["Invoice", (item) => item.invoiceId],
              ["Part", (item) => productName(item.productId)],
              ["Quantity", (item) => item.quantity],
              ["Refund", (item) => money(item.total || item.amount)],
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
                options: reportNames.map((value) => ({
                  value,
                  label: value.replaceAll("-", " "),
                })),
                value: "sales",
                required: true,
              }}
            />
            <FieldInput
              field={{ name: "dateFrom", label: "From", type: "date" }}
            />
            <FieldInput field={{ name: "dateTo", label: "To", type: "date" }} />
            <FieldInput field={{ name: "category", label: "Category" }} />
            <FieldInput field={{ name: "sku", label: "SKU" }} />
            <FieldInput
              field={{
                name: "supplierId",
                label: "Supplier",
                options: options(snapshot.suppliers || []),
              }}
            />
            <FieldInput field={{ name: "cashier", label: "Cashier ID" }} />
            <FieldInput
              field={{
                name: "paymentType",
                label: "Payment",
                options: ["Cash", "Card", "UPI"].map((value) => ({
                  value,
                  label: value,
                })),
              }}
            />
            <button className="primary-button" type="submit">
              Run report
            </button>
          </form>
          {report && (
            <>
              <div className="section-toolbar">
                <h2>{report.name}</h2>
                <button className="button" onClick={exportReport}>
                  Export CSV
                </button>
                <button className="button" onClick={() => window.print()}>
                  Print summary
                </button>
              </div>
              <div className="metrics">
                {Object.entries(report.totals || {}).map(([name, value]) => (
                  <div className="metric" key={name}>
                    <span>{name}</span>
                    <strong>
                      {typeof value === "number" &&
                      /amount|total|revenue|margin|tax|cost|discount|refund/i.test(
                        name,
                      )
                        ? money(value)
                        : String(value)}
                    </strong>
                  </div>
                ))}
              </div>
              <DataTable
                rows={report.rows || []}
                columns={Object.keys(report.rows?.[0] || {})
                  .filter((key) => typeof report.rows[0][key] !== "object")
                  .map((key) => [
                    key,
                    (item) =>
                      typeof item[key] === "number" &&
                      /amount|total|revenue|margin|tax|cost|discount|refund/i.test(
                        key,
                      )
                        ? money(item[key])
                        : String(item[key] ?? ""),
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
    if (section === "Settings")
      return <div className="settings-panel">
        <h2>{snapshot.settings?.business?.tradingName || snapshot.organization?.name || "Your business"}</h2>
        <p>{snapshot.branch?.name} · {session?.user.email} · {role}</p>
        <p>Last synchronized {formatDate(workspace?.lastSync || "")}</p>
        {role === "owner" && <>
          {(!snapshot.settings?.business?.legalName || !snapshot.settings?.business?.address) && <div className="setup-note"><strong>Complete your business details</strong><p>Enter the business name, address and tax details before issuing customer receipts.</p></div>}
          <div className="section-toolbar">
            <button className="primary-button" onClick={editBusiness}>Business details</button>
            <button className="button" onClick={editRegisterSettings}>Edit settings</button>
            <button className="button" onClick={()=>editUser()}>Create user</button>
            <button className="button" onClick={()=>editBranch()}>Add branch</button>
          </div>
          <h2>Branches</h2>
          <DataTable rows={snapshot.branches || []} columns={[["Code",item=>item.id],["Name",item=>item.name],["Address",item=>item.address]]} action={item=><button className="button" onClick={()=>editBranch(item)}>Edit branch</button>} />
          <h2>Users</h2>
          <DataTable rows={snapshot.users || []} columns={[["Name",item=>item.name],["Email",item=>item.email],["Role",item=>item.role],["Branches",item=>(item.branchIds || []).join(", ")],["Status",item=>item.active ? "Active" : "Disabled"]]} action={item=><button className="button" onClick={()=>editUser(item)}>Edit user</button>} />
        </>}
        <h2>This counter</h2>
        <p>{workspace?.device?.name || "Enrollment required for offline checkout"}</p>
        <p>Offline authorization expires {formatDate(workspace?.device?.offlineUntil)}. Session expires {formatDate(session?.expiresAt || "")}.</p>
        <p>Server: {session?.api}</p>
        {manager && <div className="section-toolbar">
          <button className="primary-button" onClick={enrollDevice}>Enroll counter</button>
          <button className="button" onClick={()=>form("Issue approval",[
            {name:"action",label:"Operation",options:["fitment","discount","return","adjustment"].map(value=>({value,label:value})),required:true},
            {name:"transactionId",label:"Transaction ID shown on cashier screen",required:true},reasonField,
          ],async data=>{
            const result=await api("/approvals",data);
            setTimeout(()=>setModal({title:"Approval issued",content:<><p>Share this ID with the cashier.</p><code>{result.id}</code></>}),0);
          })}>Issue approval</button>
        </div>}
        <button className="button" onClick={async()=>{
          await locked(deviceKey(session!),async()=>{await writeLocal("active-session",null);setSession(null);setWorkspace(null);setCart(null);});
        }}>Sign out / change branch</button>
      </div>;
    return null;
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
  function printLabel(product: Json) {
    setModal({
      title: "Print label",
      content: (
        <div className="print-label">
          <strong>{product.name}</strong>
          <Barcode value={product.barcodes?.[0] || product.sku} />
          <p>{product.sku}</p>
          <button
            className="primary-button no-print"
            onClick={() => window.print()}
          >
            Print label
          </button>
        </div>
      ),
    });
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

  const bill = quote(cart, products, snapshot.settings?.roundingIncrement || 1, snapshot.settings?.taxMode || "exclusive");
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
  const cartNeedsApproval = cart.lines.some(
    (line: Json) =>
      ["incompatible", "unverified"].includes(
        fitment(
          products.find((product) => product.id === line.productId)!,
          cart.vehicle,
        ).status,
      ) && !line.overrideReason,
  );
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
              <div className="brand-label">Automotive POS</div>
            </div>
          </div>
          <nav className="navigation" aria-label="Workspace">
            <div className="nav-label">Workspace</div>
            {sections.map((name) => (
              <button
                key={name}
                className={`nav-link ${section === name ? "is-active" : ""}`}
                aria-current={section === name ? "page" : undefined}
                onClick={() => {
                  setSection(name);
                  setSearch("");
                  setError("");
                }}
              >
                <span className="nav-icon icon-box" aria-hidden="true" />
                <span>{name}</span>
              </button>
            ))}
          </nav>
          <div className="register-info">
            <div>
              <strong>{snapshot.branch?.name || session.branchId}</strong>
              <span className="register-label">
                {session.user.name || session.user.email} · {role}
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
                  if (event.key !== "Enter" || section !== "Billing") return;
                  event.preventDefault();
                  const found = products.find((product) =>
                    [
                      product.sku,
                      product.partNumber,
                      ...(product.barcodes || []),
                      ...(product.oemReferences || []),
                    ].some((value) => normalize(value) === normalize(search)),
                  );
                  if (found) {
                    addPart(found);
                    setSearch("");
                  } else toast("No matching part found.");
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
            <button
              className="button"
              onClick={() =>
                setModal({
                  title: "Parked sales",
                  content: (
                    <div className="dialog-options">
                      {(snapshot.holds || []).map((hold: Json) => (
                        <div className="parked-row" key={hold.id}>
                          <button
                            className="dialog-option"
                            onClick={() => {
                              if (cart.lines.length) {
                                setError(
                                  "Hold or clear the current sale first.",
                                );
                                return;
                              }
                              setCart({ ...hold.cart, holdId: hold.id });
                              setModal(null);
                            }}
                          >
                            {hold.number || hold.id}
                          </button>
                          <button
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
            </button>
            {window.motorlineNative?.platform === "android" && (
              <button
                className="button"
                onClick={async () => {
                  try {
                    const code = await window.motorlineNative!.scan();
                    if (code) {
                      const part = products.find((product) =>
                        product.barcodes?.includes(code),
                      );
                      if (part) addPart(part);
                      else setSearch(code);
                    }
                  } catch (reason) {
                    fail(reason);
                  }
                }}
              >
                Scan
              </button>
            )}
          </header>
          <main id="workspace">
            <div className="workspace-heading">
              <h1>{section === "Billing" ? "Sales terminal" : section}</h1>
              <p>
                {section === "Billing"
                  ? "Build a bill for parts and services."
                  : `${snapshot.branch?.name || session.branchId} workspace`}
              </p>
            </div>
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
                  <button className="vehicle-picker" onClick={chooseVehicle}>
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
                        : "Select a vehicle to check compatibility"}
                    </span>
                  </button>
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
                              : `${available(product.id)} available`}
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
                            {fitment(product, cart.vehicle).status} ·{" "}
                            {product.partNumber}
                          </div>
                          <small className="bin-hint">
                            {stock
                              .filter(
                                (item) =>
                                  item.productId === product.id &&
                                  item.available > 0,
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
                  <label className="field">
                    <span>Customer</span>
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
                              {line.qty} × {money(line.unitPrice)} ·{" "}
                              {locationName(line.binId)}
                            </small>
                            <small
                              className={`fit-${fitment(line.product, cart.vehicle).status}`}
                            >
                              {fitment(line.product, cart.vehicle).status}
                              {line.overrideReason
                                ? " · override recorded"
                                : ""}
                            </small>
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
                                    label: "Discount amount",
                                    type: "number",
                                    min: 0,
                                    step: "0.01",
                                    required: true,
                                  },
                                  reasonField,
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
                                  if (!manager && Math.round(Number(data.discount) * 100) > (snapshot.settings.cashierDiscountLimit || 0) && !data.approvalId) throw new Error("Manager approval is required above your discount limit.");
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
                        <dd>−{money(bill.discount)}</dd>
                      </div>
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
                        disabled={!cart.lines.length || cartNeedsApproval}
                        onClick={showCheckout}
                      >
                        Checkout ↗
                      </button>
                    </div>
                    <small className="transaction-reference">
                      Transaction {cart.transactionId}
                    </small>
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
        className={`dialog ${modal?.fields && modal.fields.length > 8 ? "wide-dialog" : ""}`}
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
            <h2>{receipt.number || receipt.id}</h2>
            <h3>{receipt.business?.legalName || receipt.business?.tradingName || "Sales receipt"}</h3>
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
              {receipt.status || "Finalized"}
            </p>
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
              {(receipt.taxComponents || []).map((component:Json)=><div key={component.name}><dt>{component.name}</dt><dd>{receiptMoney(component.amount)}</dd></div>)}
              <div>
                <dt>{receipt.taxDisplayName || "Tax"}{receipt.taxMode === "inclusive" ? " included" : ""}</dt>
                <dd>{receiptMoney(receipt.tax)}</dd>
              </div>
              <div>
                <dt>Discount</dt>
                <dd>{receiptMoney(receipt.discount)}</dd>
              </div>
              <div>
                <dt>Core charges</dt>
                <dd>{receiptMoney(receipt.core || receipt.coreTotal)}</dd>
              </div>
              <div className="grand-total">
                <dt>Total</dt>
                <dd>{receiptMoney(receipt.total)}</dd>
              </div>
              <div>
                <dt>Change</dt>
                <dd>{receiptMoney(receipt.change)}</dd>
              </div>
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
              {modal.content}
              <form
                onSubmit={async (event) => {
                  event.preventDefault();
                  if (!modal.action) return;
                  setBusy(true);
                  setError("");
                  try {
                    await modal.action(
                      Object.fromEntries(new FormData(event.currentTarget)),
                    );
                    setModal(null);
                  } catch (reason) {
                    fail(reason);
                  } finally {
                    setBusy(false);
                  }
                }}
              >
                <div
                  className={
                    modal.fields && modal.fields.length > 8 ? "editor-grid" : ""
                  }
                >
                  {modal.fields?.map((field) => (
                    <FieldInput key={field.name} field={field} />
                  ))}
                </div>
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
