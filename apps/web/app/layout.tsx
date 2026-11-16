import type { Metadata } from "next";
import "./prototype.css";
import "./production.css";
export const metadata: Metadata = {
  title: "Cartunez POS",
  description: "Automotive parts, inventory, and counter billing",
  manifest: "/manifest.webmanifest",
};
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
