#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const frontRoot = join(root, "stock-front-service");

const files = {
  stockApi: read("app/lib/stock.ts"),
  authApi: read("app/lib/auth.ts"),
  home: read("app/page.tsx"),
  login: read("app/login/page.tsx"),
  packageJson: JSON.parse(read("package.json")),
  tsconfig: JSON.parse(read("tsconfig.json")),
};

const checks = [
  ["strict TypeScript is enabled", files.tsconfig.compilerOptions?.strict === true],
  ["JavaScript source is disabled", files.tsconfig.compilerOptions?.allowJs === false],
  ["axios is not used", !hasDependency("axios")],
  ["frontend uses gateway API base", files.home.includes("getStockUserProfile") && files.authApi.includes("STOCK_CLIENT_ID")],
  ["login calls local auth API", includesAll(files.authApi, ["/auth/login", "/auth/refresh", "/auth/logout"])],
  ["signup uses auth user API", files.authApi.includes('"/api/users"') && files.authApi.includes('role: "USER"')],
  ["login page has stock OAuth entries", includesAll(files.login, ["/oauth2/authorize/naver-stock", "/oauth2/authorize/kakao-stock"])],
  ["USER-only role guard exists", includesAll(files.login + files.authApi, ["isUserRole", "USER_ONLY_MESSAGE"])],
  ["market APIs are wired", includesAll(files.stockApi, [
    "/api/stock/v1/markets/instruments",
    "/api/stock/v1/markets/prices",
    "/api/stock/v1/markets/prices/",
    "/api/stock/v1/markets/order-books/",
    "/api/stock/v1/markets/rankings",
  ])],
  ["protected stock APIs are wired", includesAll(files.stockApi, [
    "/api/stock/v1/users/me",
    "/api/stock/v1/portfolio/me",
    "/api/stock/v1/portfolio/me/snapshots",
    "/api/stock/v1/orders",
    "/api/stock/v1/executions",
    "/api/stock/v1/holdings",
  ])],
  ["order mutation APIs are wired", includesAll(files.stockApi, ["placeOrder", "cancelOrder", "postJson<Order>", "deleteJson<Order>"])],
  ["auth refresh retry wraps protected APIs", countOccurrences(files.stockApi, "withAuthRefresh(token") >= 7],
  ["dashboard renders portfolio, market, holdings, order book, rankings, orders, executions", includesAll(files.home, [
    "총 자산",
    "시장 가격",
    "보유 종목",
    "주문장",
    "랭킹",
    "주문 입력",
    "주문 상태",
    "최근 체결",
  ])],
  ["dashboard supports LIMIT and MARKET order types", includesAll(files.home, ['"LIMIT"', '"MARKET"', "지정가", "시장가"])],
  ["dashboard exposes BUY and SELL order sides", includesAll(files.home, ['"BUY"', '"SELL"', "매수", "매도"])],
  ["dashboard exposes pending order cancellation", includesAll(files.home, ["cancel(order.id)", "cancellingOrderId", "취소"])],
  ["dashboard shows settlement history", includesAll(files.home, ["자산 기록", "PortfolioHistory", "장 마감 정산"])],
  ["dashboard shows price tick history", includesAll(files.home, ["가격 흐름", "Sparkline", "getPriceTicks"])],
];

const failed = checks.filter(([, ok]) => !ok);

for (const [label, ok] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
}

if (failed.length) {
  console.error(`stock front contract failed: ${failed.length} check(s)`);
  process.exit(1);
}

console.log("stock front contract passed");

function read(relativePath) {
  return readFileSync(join(frontRoot, relativePath), "utf8");
}

function includesAll(text, needles) {
  return needles.every((needle) => text.includes(needle));
}

function hasDependency(name) {
  return Boolean(files.packageJson.dependencies?.[name] || files.packageJson.devDependencies?.[name]);
}

function countOccurrences(text, needle) {
  let count = 0;
  let offset = 0;
  while (true) {
    const index = text.indexOf(needle, offset);
    if (index === -1) {
      return count;
    }
    count += 1;
    offset = index + needle.length;
  }
}
