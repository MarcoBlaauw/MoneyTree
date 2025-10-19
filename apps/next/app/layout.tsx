import type { Metadata } from "next";
import { headers } from "next/headers";
import { Fira_Code, Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
});

const firaCode = Fira_Code({
  subsets: ["latin"],
  variable: "--font-fira-code",
});

export const metadata: Metadata = {
  title: "MoneyTree Next",
  description: "Next.js frontend powered by the shared MoneyTree UI kit.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const cspNonce = headers().get("x-csp-nonce") ?? undefined;

  return (
    <html lang="en">
      <head>
        <style nonce={cspNonce}>{":root { color-scheme: light; }"}</style>
      </head>
      <body data-csp-nonce={cspNonce} className={`${inter.variable} ${firaCode.variable} font-sans`}>
        {children}
      </body>
    </html>
  );
}
