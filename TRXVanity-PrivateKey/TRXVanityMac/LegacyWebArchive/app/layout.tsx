import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "TRX 靓号生成器 | 本地多线程",
  description:
    "在浏览器本地并发生成自定义前段和尾号数字的 TRON 地址与对应私钥。",
};

export const viewport: Viewport = {
  themeColor: "#f4f1e9",
  colorScheme: "light",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}

