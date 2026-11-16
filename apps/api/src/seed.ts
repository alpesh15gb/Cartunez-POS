import type { Database } from "./db.js";
import { getRecord, putRecord } from "./db.js";
import { hashPassword, adjust } from "./domain.js";

export async function seed(db: Database) {
  if (process.env.NODE_ENV === "production")
    throw new Error("Demo seeding is disabled in production.");
  if (await getRecord(db, "demo", "organization", "demo")) return;
  await db.transaction(async (tx) => {
    await putRecord(tx, "demo", "organization", {
      id: "demo",
      name: "Motorline Demo",
      currency: "INR",
    });
    await putRecord(tx, "demo", "settings", {
      id: "settings",
      currency: "INR",
      invoicePrefix: "ML",
      nextInvoice: 1000,
      nextDeviceNumber: 100000,
      offlineHours: 24,
      offlineTenders: ["Cash"],
      sessionHours: 8,
      cashierDiscountLimit: 0,
      roundingIncrement: 1,
      taxRates: [0, 500, 1200, 1800, 2800],
    });
    for (const branch of [
      { id: "pune", name: "Pune Main" },
      { id: "mumbai", name: "Mumbai Branch" },
    ]) {
      await putRecord(tx, "demo", "branch", branch);
      for (const [suffix, area, rack, shelf, bin, kind] of [
        ["a1", "Main store", "A", "1", "01", "sellable"],
        ["a2", "Main store", "A", "2", "01", "sellable"],
        ["b1", "Back store", "B", "1", "01", "sellable"],
        ["damaged", "Returns", "D", "1", "01", "damaged"],
        ["warranty", "Returns", "W", "1", "01", "warranty"],
      ]) {
        await putRecord(
          tx,
          "demo",
          "location",
          {
            id: branch.id === "pune" ? `bin-${suffix}` : `mumbai-${suffix}`,
            branchId: branch.id,
            area,
            rack,
            shelf,
            bin,
            kind,
          },
          branch.id,
        );
      }
    }
    for (const role of ["owner", "manager", "cashier", "inventory"]) {
      await putRecord(tx, "demo", "user", {
        id: `user-${role}`,
        organizationId: "demo",
        name: role[0].toUpperCase() + role.slice(1),
        email: `${role}@motorline.local`,
        passwordHash: hashPassword(
          process.env.DEMO_PASSWORD || "MotorlineDemo123!",
        ),
        role,
        branchIds: role === "cashier" ? ["pune"] : ["pune", "mumbai"],
        active: true,
      });
    }
    await putRecord(tx, "demo", "supplier", {
      id: "supplier-1",
      name: "Fictional Auto Supply",
      phone: "9000000001",
      email: "supplier@example.test",
    });
    await putRecord(tx, "demo", "customer", {
      id: "customer-1",
      name: "Arjun Demo",
      phone: "9000000101",
      email: "",
    });
    const vehicles = [
      {
        id: "swift",
        make: "Maruti Suzuki",
        model: "Swift",
        year: 2022,
        engine: "1.2L",
        fuel: "Petrol",
      },
      {
        id: "city",
        make: "Honda",
        model: "City",
        year: 2021,
        engine: "1.5L",
        fuel: "Petrol",
      },
      {
        id: "i20",
        make: "Hyundai",
        model: "i20",
        year: 2021,
        engine: "1.2L",
        fuel: "Petrol",
      },
    ];
    for (const vehicle of vehicles)
      await putRecord(tx, "demo", "vehicle", vehicle);
    const names = [
      "Synthetic Engine Oil",
      "Spin-On Oil Filter",
      "Front Brake Kit",
      "Iridium Spark Plug",
      "45Ah Car Battery",
      "Wiper Blade Pair",
      "Engine Air Filter",
      "Long-Life Coolant",
      "Headlamp Bulb",
      "Drive Belt",
      "DOT 4 Brake Fluid",
      "Oil Change Labour",
    ];
    const icons = [
      "oil",
      "filter",
      "brake",
      "spark",
      "battery",
      "wiper",
      "air-filter",
      "coolant",
      "bulb",
      "belt",
      "brake-fluid",
      "service",
    ];
    const prices = [
      219900, 28500, 185000, 74900, 549900, 79900, 64900, 69900, 29900, 78900,
      32000, 45000,
    ];
    for (let i = 0; i < icons.length; i++) {
      const universal = [0, 7, 10, 11].includes(i);
      const vehicle = vehicles[i === 3 ? 1 : 0];
      const fitments =
        universal || i === 9
          ? []
          : [
              {
                id: `fit-${icons[i]}`,
                productId: icons[i],
                make: vehicle.make,
                model: vehicle.model,
                yearFrom: 2018,
                yearTo: 2025,
                engine: vehicle.engine,
                fuel: vehicle.fuel,
                exclusions: [],
                source: "Fictional demonstration data",
                effectiveFrom: "2020-01-01",
              },
            ];
      await putRecord(tx, "demo", "product", {
        id: icons[i],
        sku: `ML-${icons[i].toUpperCase()}-01`,
        name: names[i],
        brand: "Motorline Demo",
        partNumber: `ML ${500 + i}-01`,
        oemReferences: [`OEM-${i + 1}`],
        barcodes: [`89000000${String(i + 1).padStart(5, "0")}`],
        description: "Fictional demonstration product",
        category: universal ? "Fluids" : i === 2 ? "Brakes" : "Parts",
        unit: "Each",
        packSize: 1,
        supplierId: "supplier-1",
        supplierReferences: [],
        cost: Math.round(prices[i] * 0.6),
        retailPrice: prices[i],
        wholesalePrice: Math.round(prices[i] * 0.9),
        taxRate: 1800,
        taxCategory: "Standard",
        reorderLevel: 5,
        serialTracked: false,
        coreCharge: i === 4 ? 50000 : 0,
        universal,
        alternatives: [],
        supersedes: [],
        interchanges: [],
        icon: icons[i],
        type: i === 11 ? "service" : "part",
        fitments,
      });
      if (i !== 11) {
        const actor = {
          id: "seed",
          organizationId: "demo",
          branchId: "pune",
          role: "owner",
          name: "Seed",
        };
        await adjust(
          tx,
          actor,
          icons[i],
          "bin-a1",
          20 - i,
          "Opening stock",
          "seed",
        );
        await adjust(tx, actor, icons[i], "bin-a2", 5, "Opening stock", "seed");
      }
    }
  });
}
