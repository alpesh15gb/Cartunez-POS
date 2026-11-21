// WS-E: a fake Magento 2.4 store for the online order fulfilment tests.
/**
 * Magento with editable orders: ship (can fail, or ship and lose its reply),
 * order read, shipment search and tracking, and order invoices.
 */
export function fakeMagento() {
  const orders: any[] = [];
  const shipments: any[] = [];
  const invoices: any[] = [];
  const tracks: any[] = [];
  const calls: string[] = [];
  let shipFailures = 0;
  let lostReplies = 0;
  let clock = Date.now();
  const stamp = () => new Date((clock = Math.max(Date.now(), clock + 1000))).toISOString().slice(0, 19).replace("T", " ");
  const fetch = (async (url: string | URL, init: any = {}) => {
    const u = new URL(String(url));
    const method = init.method || "GET";
    calls.push(`${method} ${u.pathname}`);
    const reply = (status: number, data: unknown) =>
      new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
    if (init.headers?.Authorization !== "Bearer test-token") return reply(401, { message: "Unauthorized" });
    if (u.pathname === "/rest/V1/store/storeConfigs") return reply(200, [{ base_currency_code: "INR" }]);
    if (u.pathname === "/rest/all/V1/orders") {
      const since = u.searchParams.get("searchCriteria[filter_groups][0][filters][0][value]")!;
      const items = orders.filter((o) => o.updated_at >= since);
      return reply(200, { items, total_count: items.length });
    }
    const read = u.pathname.match(/^\/rest\/V1\/orders\/(\d+)$/);
    if (read && method === "GET") {
      const o = orders.find((x) => x.entity_id === Number(read[1]));
      return o ? reply(200, o) : reply(404, { message: "The entity that was requested doesn't exist." });
    }
    const ship = u.pathname.match(/^\/rest\/V1\/order\/(\d+)\/ship$/);
    if (ship && method === "POST") {
      if (shipFailures > 0) {
        shipFailures--;
        return reply(500, { message: "Magento is busy." });
      }
      const o = orders.find((x) => x.entity_id === Number(ship[1]));
      const body = JSON.parse(init.body);
      for (const item of body.items) {
        const line = o.items.find((i: any) => i.item_id === item.order_item_id);
        if (!line || item.qty <= 0 || item.qty > line.qty_ordered - (line.qty_shipped || 0) - line.qty_canceled - line.qty_refunded)
          return reply(400, { message: "Shipment Document Validation Error(s): The order does not allow a shipment to be created." });
        line.qty_shipped = (line.qty_shipped || 0) + item.qty;
      }
      const entity_id = 900 + shipments.length + 1;
      shipments.push({ orderId: Number(ship[1]), entity_id, body, tracks: body.tracks || [] });
      o.updated_at = stamp();
      if (lostReplies > 0) {
        lostReplies--;
        return reply(504, { message: "Gateway timeout" });
      }
      return reply(200, entity_id);
    }
    if (u.pathname === "/rest/V1/shipments" && method === "GET") {
      const orderId = Number(u.searchParams.get("searchCriteria[filter_groups][0][filters][0][value]"));
      const items = shipments.filter((s) => s.orderId === orderId).map((s) => ({ entity_id: s.entity_id, order_id: s.orderId, tracks: s.tracks }));
      return reply(200, { items, total_count: items.length });
    }
    if (u.pathname === "/rest/V1/shipment/track" && method === "POST") {
      const { entity } = JSON.parse(init.body);
      tracks.push(entity);
      shipments.find((s) => s.entity_id === entity.parent_id)?.tracks.push(entity);
      return reply(200, { entity_id: 700 + tracks.length, ...entity });
    }
    const invoice = u.pathname.match(/^\/rest\/V1\/order\/(\d+)\/invoice$/);
    if (invoice && method === "POST") {
      const o = orders.find((x) => x.entity_id === Number(invoice[1]));
      if (o.items.every((i: any) => i.qty_invoiced >= i.qty_ordered - i.qty_canceled))
        return reply(400, { message: "The order does not allow an invoice to be created." });
      for (const i of o.items) i.qty_invoiced = i.qty_ordered - i.qty_canceled;
      invoices.push({ orderId: o.entity_id, body: JSON.parse(init.body) });
      o.updated_at = stamp();
      return reply(200, 500 + invoices.length);
    }
    if (u.pathname.startsWith("/rest/all/V1/products/")) return reply(200, { id: 1, sku: "x" });
    return reply(404, { message: "Not found" });
  }) as typeof globalThis.fetch;
  const order = (n: number, items: [string, number][], extra: any = {}) => {
    const o = {
      entity_id: n, increment_id: `10000000${n}`, state: "new", status: "pending",
      created_at: stamp(), updated_at: stamp(),
      customer_firstname: "Asha", customer_lastname: "Rao", customer_email: `asha${n}@example.com`,
      grand_total: 100 * items.reduce((s, [, qty]) => s + qty, 0), order_currency_code: "INR",
      payment: { method: "razorpay", additional_information: ["Razorpay"] },
      extension_attributes: { shipping_assignments: [{ shipping: { address: { street: ["12 MG Road"], city: "Pune", postcode: "411001", region: "Maharashtra", region_code: "MH", telephone: "98000000" + n } } }] },
      items: items.map(([sku, qty], i) => ({ item_id: n * 10 + i, sku, name: sku, qty_ordered: qty, qty_invoiced: 0, qty_shipped: 0, qty_canceled: 0, qty_refunded: 0, price_incl_tax: 100, row_total_incl_tax: 100 * qty, discount_amount: 0 })),
      ...extra,
    };
    orders.push(o);
    return o;
  };
  const update = (o: any, change: (item: any) => void) => {
    o.items.forEach(change);
    o.updated_at = stamp();
  };
  return {
    fetch, order, update, shipments, invoices, tracks, calls,
    failShipments: (n: number) => (shipFailures = n),
    loseShipReplies: (n: number) => (lostReplies = n),
  };
}
