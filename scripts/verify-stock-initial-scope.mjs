#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;

const initialCorporateActionTypes = [
  "INITIAL_ISSUE",
  "PAID_IN_CAPITAL_INCREASE",
  "ADDITIONAL_ISSUE",
  "STOCK_SPLIT",
  "CASH_DIVIDEND",
  "BONUS_ISSUE",
  "STOCK_DIVIDEND",
];

const adminCorporateActionTypes = initialCorporateActionTypes.filter((type) => type !== "INITIAL_ISSUE");
const deferredCorporateActionTypes = [
  "SPECIAL_DIVIDEND",
  "CAPITAL_REDUCTION",
  "REVERSE_SPLIT",
  "RIGHTS_OFFERING",
  "MERGER",
  "SPIN_OFF",
  "DELISTING",
];

const allowedOrderTypes = ["LIMIT", "MARKET"];
const deferredOrderFeatures = ["STOP", "STOP_LIMIT", "IOC", "FOK", "GTC", "GTD", "CALL_AUCTION", "PRE_OPEN", "AFTER_HOURS"];
const allowedMarketTypes = ["VIRTUAL_PRICE", "ORDER_BOOK"];
const allowedMarketSessionStatuses = ["OPEN", "CLOSED", "HALTED"];

const files = {
  corporateActionEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/StockCorporateActionType.java"),
  orderTypeEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/OrderType.java"),
  marketTypeEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/MarketType.java"),
  marketSessionStatusEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/MarketSessionStatus.java"),
  envExample: read(".env.example"),
  stockBackApplication: read("stock-back-service/src/main/resources/application.yml"),
  stockBackLocalDirect: read("stock-back-service/src/main/resources/application-local-direct.yml"),
  stockBackBuild: read("stock-back-service/build.gradle"),
  stockBatchApplication: read("stock-batch-service/src/main/resources/application.yml"),
  stockBatchLocalDirect: read("stock-batch-service/src/main/resources/application-local-direct.yml"),
  stockBatchApplicationClass: read("stock-batch-service/src/main/java/stock/batch/service/StockBatchServiceApplication.java"),
  stockBatchBuild: read("stock-batch-service/build.gradle"),
  stockBatchReadme: read("stock-batch-service/README.md"),
  stockBatchArchitecture: read("stock-batch-service/docs/architecture.md"),
  stockBatchMetadataMysqlDdl: read("stock-batch-service/src/main/resources/db/schema/batch-metadata-mysql.sql"),
  stockBatchMetadataH2Ddl: read("stock-batch-service/src/main/resources/db/schema/batch-metadata-h2.sql"),
  frontApi: read("stock-front-service/app/lib/api.ts"),
  frontAuth: read("stock-front-service/app/lib/auth.ts"),
  frontStockApi: read("stock-front-service/app/lib/stock.ts"),
  frontEnvExample: read("stock-front-service/.env.example"),
  frontNextConfig: read("stock-front-service/next.config.ts"),
  frontTypes: read("stock-front-service/app/types/stock.ts"),
  frontAdmin: read("stock-front-service/app/supply-demand/admin/page.tsx"),
  frontContractVerifier: read("scripts/verify-stock-front-contract.mjs"),
  stockSystemController: read("stock-back-service/src/main/java/stock/back/service/common/act/StockSystemController.java"),
  stockAccountController: read("stock-back-service/src/main/java/stock/back/service/trading/act/AccountController.java"),
  stockUserController: read("stock-back-service/src/main/java/stock/back/service/user/act/StockUserController.java"),
  stockTradingController: read("stock-back-service/src/main/java/stock/back/service/trading/act/TradingController.java"),
  stockMarketController: read("stock-back-service/src/main/java/stock/back/service/market/act/MarketController.java"),
  stockBatchJobController: read("stock-batch-service/src/main/java/stock/batch/service/common/act/StockBatchJobController.java"),
  stockBatchSystemController: read("stock-batch-service/src/main/java/stock/batch/service/common/act/StockBatchSystemController.java"),
  stockBackApiSurfaceTest: read("stock-back-service/src/test/java/stock/back/service/common/config/StockBackApiSurfaceContractTest.java"),
  stockBatchApiSurfaceTest: read("stock-batch-service/src/test/java/stock/batch/service/common/config/StockBatchApiSurfaceContractTest.java"),
  stockSmoke: read("scripts/stock-smoke.sh"),
  stockH2Smoke: read("scripts/stock-h2-smoke.sh"),
  stockGatewayH2Smoke: read("scripts/stock-gateway-h2-smoke.sh"),
  stockBatchApplicationTest: read("stock-batch-service/src/main/resources/application-test.yml"),
  stockBackSmokeProfile: read("stock-back-service/src/main/resources/application-smoke.yml"),
  stockBatchSmokeProfile: read("stock-batch-service/src/main/resources/application-smoke.yml"),
  auditDoc: read("stock-back-service/docs/market-simulation/16-initial-essential-scope-audit.md"),
  completionEvidenceDoc: read("stock-back-service/docs/market-simulation/17-essential-completion-evidence.md"),
};

const defaultSeedMarkers = [
  "INSERT INTO stock_instrument",
  "INSERT INTO stock_price",
  "INSERT INTO stock_virtual_market_config",
  "INSERT INTO stock_auto_participant",
  "MERGE INTO stock_virtual_market_config",
  "MERGE INTO stock_order_book_instrument",
  "MERGE INTO stock_auto_participant",
  "삼성전자",
  "'seed'",
  "stock-auto-001",
];

const ddlPaths = [
  "stock-back-service/src/main/resources/db/ddl/stock_all.sql",
  "stock-back-service/src/main/resources/db/ddl/stock_market_execution_split_alter.sql",
  "stock-batch-service/src/main/resources/db/ddl/stock_all.sql",
  "stock-batch-service/src/main/resources/db/ddl/stock_h2.sql",
  "stock-batch-service/src/main/resources/db/ddl/stock_market_execution_split_alter.sql",
];

const fullSchemaDdlPaths = [
  "stock-back-service/src/main/resources/db/ddl/stock_all.sql",
  "stock-batch-service/src/main/resources/db/ddl/stock_all.sql",
  "stock-batch-service/src/main/resources/db/ddl/stock_h2.sql",
];

const batchMetadataMarkers = [
  "BATCH_JOB_INSTANCE",
  "BATCH_JOB_EXECUTION",
  "BATCH_JOB_EXECUTION_PARAMS",
  "BATCH_STEP_EXECUTION",
  "BATCH_STEP_EXECUTION_CONTEXT",
  "BATCH_JOB_EXECUTION_CONTEXT",
  "BATCH_STEP_EXECUTION_SEQ",
  "BATCH_JOB_EXECUTION_SEQ",
  "BATCH_JOB_INSTANCE_SEQ",
];

const mainSourcePaths = [
  "stock-back-service/src/main",
  "stock-batch-service/src/main",
  "stock-front-service/app",
];

const schedulerDisableMarkers = [
  "market-data:\n      enabled: false",
  "virtual-price-execution:\n      enabled: false",
  "order-book-execution:\n      enabled: false",
  "corporate-actions:\n      enabled: false",
  "auto-market:\n      enabled: false",
  "settlement:\n      enabled: false",
];

const stockBackApiSurface = [
  '@RequestMapping("/api/stock/v1/system")',
  '@GetMapping("/status")',
  '@RequestMapping("/api/stock/v1/accounts")',
  '@GetMapping("/me")',
  '@GetMapping("/me/status")',
  '@PostMapping("/me")',
  '@RequestMapping("/api/stock/v1/users")',
  '@RequestMapping("/api/stock/v1")',
  '@GetMapping("/portfolio/me")',
  '@GetMapping("/portfolio/me/snapshots")',
  '@GetMapping("/portfolio/me/profit-summary")',
  '@GetMapping("/orders")',
  '@PostMapping("/orders")',
  '@DeleteMapping("/orders/{orderId}")',
  '@PatchMapping("/orders/{orderId}")',
  '@PostMapping("/orders/{orderId}/cancel")',
  '@GetMapping("/executions")',
  '@GetMapping("/holdings")',
  '@RequestMapping("/api/stock/v1/markets")',
  '@GetMapping("/instruments")',
  '@GetMapping("/order-book-instruments")',
  '@PostMapping("/order-book-instruments")',
  '@PostMapping("/order-book-instruments/{symbol}/corporate-actions")',
  '@GetMapping("/order-book-instruments/{symbol}/corporate-actions")',
  '@GetMapping("/order-book-instruments/{symbol}/reports")',
  '@GetMapping("/order-book-instruments/{symbol}/reports/latest")',
  '@PostMapping("/order-book-instruments/{symbol}/reports")',
  '@PatchMapping("/order-book-instruments/{symbol}/reports")',
  '@DeleteMapping("/order-book-instruments/{symbol}/reports")',
  '@GetMapping("/corporate-action-entitlements/me")',
  '@PatchMapping("/{marketType}/symbols/{symbol}/status")',
  '@GetMapping("/prices")',
  '@GetMapping(value = "/prices/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)',
  '@GetMapping("/prices/{symbol}/ticks")',
  '@GetMapping("/order-books/{symbol}")',
  '@GetMapping("/rankings")',
  '@GetMapping("/virtual-market")',
  '@GetMapping("/order-book-market")',
  '@GetMapping("/auto-market")',
];

const stockBatchApiSurface = [
  '@RequestMapping("/internal/stock-batch/v1/system")',
  '@GetMapping("/status")',
  '@RequestMapping("/internal/stock-batch/v1/jobs")',
  '@PostMapping("/market-data/refresh")',
  '@PostMapping("/virtual-price-execution/run")',
  '@PostMapping("/order-book-execution/run")',
  '@PostMapping("/auto-market/run")',
  '@PostMapping("/portfolio-settlement/run")',
  '@PostMapping("/corporate-actions/run")',
];

const stockBackApiSurfaceRoutes = [
  "GET /api/stock/v1/system/status",
  "GET /api/stock/v1/accounts/me",
  "GET /api/stock/v1/accounts/me/status",
  "POST /api/stock/v1/accounts/me",
  "GET /api/stock/v1/users/me",
  "GET /api/stock/v1/portfolio/me",
  "GET /api/stock/v1/portfolio/me/snapshots",
  "GET /api/stock/v1/portfolio/me/profit-summary",
  "GET /api/stock/v1/orders",
  "POST /api/stock/v1/orders",
  "DELETE /api/stock/v1/orders/{orderId}",
  "PATCH /api/stock/v1/orders/{orderId}",
  "POST /api/stock/v1/orders/{orderId}/cancel",
  "GET /api/stock/v1/executions",
  "GET /api/stock/v1/holdings",
  "GET /api/stock/v1/markets/instruments",
  "GET /api/stock/v1/markets/order-book-instruments",
  "POST /api/stock/v1/markets/order-book-instruments",
  "POST /api/stock/v1/markets/order-book-instruments/{symbol}/corporate-actions",
  "GET /api/stock/v1/markets/order-book-instruments/{symbol}/corporate-actions",
  "GET /api/stock/v1/markets/order-book-instruments/{symbol}/reports",
  "GET /api/stock/v1/markets/order-book-instruments/{symbol}/reports/latest",
  "POST /api/stock/v1/markets/order-book-instruments/{symbol}/reports",
  "PATCH /api/stock/v1/markets/order-book-instruments/{symbol}/reports",
  "DELETE /api/stock/v1/markets/order-book-instruments/{symbol}/reports",
  "GET /api/stock/v1/markets/corporate-action-entitlements/me",
  "PATCH /api/stock/v1/markets/{marketType}/symbols/{symbol}/status",
  "GET /api/stock/v1/markets/prices",
  "GET /api/stock/v1/markets/prices/stream",
  "GET /api/stock/v1/markets/prices/{symbol}/ticks",
  "GET /api/stock/v1/markets/order-books/{symbol}",
  "GET /api/stock/v1/markets/rankings",
  "GET /api/stock/v1/markets/virtual-market",
  "GET /api/stock/v1/markets/order-book-market",
  "GET /api/stock/v1/markets/auto-market",
];

const stockBatchApiSurfaceRoutes = [
  "GET /internal/stock-batch/v1/system/status",
  "POST /internal/stock-batch/v1/jobs/market-data/refresh",
  "POST /internal/stock-batch/v1/jobs/virtual-price-execution/run",
  "POST /internal/stock-batch/v1/jobs/order-book-execution/run",
  "POST /internal/stock-batch/v1/jobs/auto-market/run",
  "POST /internal/stock-batch/v1/jobs/portfolio-settlement/run",
  "POST /internal/stock-batch/v1/jobs/corporate-actions/run",
];

const checks = [
  [
    "back corporate action enum is initial scope only",
    arraysEqual(parseJavaEnum(files.corporateActionEnum, "StockCorporateActionType"), initialCorporateActionTypes),
  ],
  [
    "back order type enum is LIMIT and MARKET only",
    arraysEqual(parseJavaEnum(files.orderTypeEnum, "OrderType"), allowedOrderTypes),
  ],
  [
    "back market type enum keeps two market families only",
    arraysEqual(parseJavaEnum(files.marketTypeEnum, "MarketType"), allowedMarketTypes),
  ],
  [
    "back market session status keeps minimal states only",
    arraysEqual(parseJavaEnum(files.marketSessionStatusEnum, "MarketSessionStatus"), allowedMarketSessionStatuses),
  ],
  [
    "front corporate action type matches initial scope",
    arraysEqual(parseTsUnion(files.frontTypes, "CorporateActionType"), initialCorporateActionTypes),
  ],
  [
    "front order type keeps LIMIT and MARKET only",
    arraysEqual(parseTsUnion(files.frontTypes, "OrderType"), allowedOrderTypes),
  ],
  [
    "front market type keeps two market families only",
    arraysEqual(parseTsUnion(files.frontTypes, "MarketType"), allowedMarketTypes),
  ],
  [
    "front market session status keeps minimal states only",
    arraysEqual(parseTsUnion(files.frontTypes, "MarketSessionStatus"), allowedMarketSessionStatuses),
  ],
  [
    "admin corporate action choices exclude INITIAL_ISSUE and deferred actions",
    includesAll(files.frontAdmin, adminCorporateActionTypes.map((type) => `value="${type}"`))
      && !files.frontAdmin.includes('value="INITIAL_ISSUE"')
      && !includesAny(files.frontAdmin, deferredCorporateActionTypes),
  ],
  [
    "front contract verifier guards deferred corporate actions",
    includesAll(files.frontContractVerifier, deferredCorporateActionTypes),
  ],
  [
    "initial scope audit document is present and points to code contracts",
    includesAll(files.auditDoc, [
      "현재 필수로 유지하는 기능",
      "의도적으로 제외한 것",
      "코드상 범위 고정 지점",
      "검증 명령",
      "StockCorporateActionType.java",
      "StockBackApiSurfaceContractTest",
      "StockBatchApiSurfaceContractTest",
      "verify-stock-front-contract.mjs",
    ]),
  ],
  [
    "initial scope completion evidence document maps requirements to verification",
    includesAll(files.completionEvidenceDoc, [
      "Essential Completion Evidence",
      "요구사항별 증거",
      "필수 검증 명령",
      "StockBackApiSurfaceContractTest",
      "StockBatchApiSurfaceContractTest",
      "verify-stock-initial-scope.mjs",
      "npm run verify:contract",
      "완료로 보지 않는 경우",
    ]),
  ],
  [
    "DDL resources keep corporate action scope and constraints",
    ddlPaths.every((path) => {
      const ddl = read(path);
      return includesAll(ddl, initialCorporateActionTypes)
        && includesAll(ddl, [
          "chk_stock_corporate_action_type_valid",
          "chk_stock_corporate_action_field_scope",
          "chk_stock_corporate_action_initial_listed",
        ])
        && !includesAny(ddl, deferredCorporateActionTypes);
    }),
  ],
  [
    "DDL resources keep initial order and market scopes",
    fullSchemaDdlPaths.every((path) => {
      const ddl = read(path);
      return includesAll(ddl, allowedOrderTypes.map((type) => `WHEN '${type}'`))
        && includesAll(ddl, allowedMarketTypes.map((type) => `WHEN '${type}'`))
        && includesAll(ddl, allowedMarketSessionStatuses.map((status) => `WHEN '${status}'`));
    }),
  ],
  [
    "stock batch uses separate Spring Batch 6 JDBC metadata schema",
    files.stockBatchBuild.includes("spring-boot-starter-batch-jdbc")
      && files.stockBatchApplication.includes("repository:\n      schema:")
      && files.stockBatchApplication.includes("datasource:\n        url: jdbc:mysql://kimd0.iptime.org:23306/STOCK_BATCH_METADATA")
      && files.stockBatchApplication.includes("STOCK_BATCH_METADATA")
      && includesAll(files.stockBatchMetadataMysqlDdl, batchMetadataMarkers)
      && includesAll(files.stockBatchMetadataH2Ddl, batchMetadataMarkers)
      && !files.stockBatchMetadataMysqlDdl.includes("BATCH_JOB_SEQ")
      && !files.stockBatchMetadataH2Ddl.includes("BATCH_JOB_SEQ")
      && files.stockBatchReadme.includes("Batch metadata schema: `STOCK_BATCH_METADATA`")
      && files.stockBatchArchitecture.includes("Spring Batch: 6.x line with JDBC `JobRepository`"),
  ],
  [
    "non-smoke DDL resources do not seed a default market",
    ddlPaths.every((path) => !includesAny(read(path), defaultSeedMarkers)),
  ],
  [
    "stock smoke defaults do not assume seeded market or symbol",
    includesAll(files.envExample, [
      "STOCK_SMOKE_EXPECT_SEEDED_MARKET=false",
      "STOCK_SMOKE_SYMBOL=",
    ])
      && includesAll(files.stockSmoke, [
        'STOCK_SMOKE_EXPECT_SEEDED_MARKET="${STOCK_SMOKE_EXPECT_SEEDED_MARKET:-false}"',
        'STOCK_SMOKE_SYMBOL="${STOCK_SMOKE_SYMBOL:-}"',
        "STOCK_SMOKE_SYMBOL is required when seeded market or order placement smoke checks are enabled",
      ]),
  ],
  [
    "seeded 005930 smoke data is limited to explicit smoke profiles",
    includesAll(files.stockBackSmokeProfile, ["on-profile: smoke", "stock_h2_smoke_data.sql"])
      && includesAll(files.stockBatchSmokeProfile, ["on-profile: smoke", "stock_h2_smoke_data.sql"])
      && includesAll(files.stockH2Smoke, ['STOCK_SMOKE_SYMBOL="${STOCK_SMOKE_SYMBOL:-005930}"'])
      && includesAll(files.stockGatewayH2Smoke, [
        'export STOCK_SMOKE_EXPECT_SEEDED_MARKET="${STOCK_SMOKE_EXPECT_SEEDED_MARKET:-true}"',
        'export STOCK_SMOKE_SYMBOL="${STOCK_SMOKE_SYMBOL:-005930}"',
      ]),
  ],
  [
    "main sources do not contain deferred corporate actions or advanced order types",
    !includesAny(readTree(mainSourcePaths), [...deferredCorporateActionTypes, ...deferredOrderFeatures]),
  ],
  [
    "stock-back-service does not own scheduler execution",
    !readTree(["stock-back-service/src/main/java"]).includes("@Scheduled")
      && !readTree(["stock-back-service/src/main/java"]).includes("@EnableScheduling"),
  ],
  [
    "stock batch test profile disables all background schedulers",
    includesAll(files.stockBatchApplicationTest, schedulerDisableMarkers),
  ],
  [
    "stock services default to local-direct profile",
    includesAll(files.stockBackApplication, ["active: local-direct", "local-direct:"])
      && includesAll(files.stockBatchApplication, ["active: local-direct", "local-direct:"]),
  ],
  [
    "local-direct profile disables discovery and back calls auth directly",
    includesAll(files.stockBackLocalDirect, [
      "discovery:\n      enabled: false",
      "auto-registration:\n        enabled: false",
      "enabled: false",
      "registerWithEureka: false",
      "fetchRegistry: false",
      "url: ${STOCK_AUTH_BASE_URL:http://localhost:9000}",
      "allowed-origins: ${STOCK_CORS_ALLOWED_ORIGINS:http://localhost:3005,http://127.0.0.1:3005}",
    ])
      && includesAll(files.stockBatchLocalDirect, [
        "discovery:\n      enabled: false",
        "auto-registration:\n        enabled: false",
        "enabled: false",
        "registerWithEureka: false",
        "fetchRegistry: false",
      ]),
  ],
  [
    "stock front defaults to direct API mode with optional gateway mode",
    includesAll(files.frontApi, [
      'process.env.NEXT_PUBLIC_API_MODE ?? "direct"',
      'const DEFAULT_GATEWAY_API_BASE = "http://localhost:8080"',
      'const DEFAULT_DIRECT_STOCK_API_BASE = "http://localhost:20480"',
      'const DEFAULT_DIRECT_AUTH_API_BASE = "http://localhost:9000"',
      "isGatewayMode ? DEFAULT_GATEWAY_API_BASE : DEFAULT_DIRECT_STOCK_API_BASE",
      "isGatewayMode ? DEFAULT_GATEWAY_API_BASE : DEFAULT_DIRECT_AUTH_API_BASE",
      'export const STOCK_CLIENT_ID = "stock-front-service"',
    ])
      && includesAll(files.frontEnvExample, [
        "NEXT_PUBLIC_API_MODE=direct",
        "NEXT_PUBLIC_STOCK_API_URL=http://localhost:20480",
        "NEXT_PUBLIC_AUTH_API_URL=http://localhost:9000",
        "# NEXT_PUBLIC_API_MODE=gateway",
        "# NEXT_PUBLIC_API_URL=http://localhost:8080",
      ]),
  ],
  [
    "stock front local-direct auth headers and client id are wired",
    includesAll(files.frontAuth, [
      '"X-Client-Id": STOCK_CLIENT_ID',
      "/auth/login",
      "/auth/refresh",
      "/auth/logout",
      'role: "USER"',
    ])
      && includesAll(files.frontStockApi, [
        "Authorization: `Bearer ${token}`",
        '"X-User-Key": user.userKey',
        '"X-User-Role": user.role',
      ]),
  ],
  [
    "stock front dev origin stays scoped to known host only",
    includesAll(files.frontNextConfig, [
      "allowedDevOrigins",
      '"61.80.148.197"',
      '"61.80.148.197:3005"',
    ])
      && !files.frontNextConfig.includes('"0.0.0.0"')
      && !files.frontNextConfig.includes('"*"'),
  ],
  [
    "stock project does not keep docker compose artifacts",
    listFiles(join(root, "stock-back-service"))
      .concat(listFiles(join(root, "stock-batch-service")))
      .concat(listFiles(join(root, "stock-front-service")))
      .concat(listFiles(join(root, "scripts")))
      .every((path) => !/(^|\/)(docker-compose|compose)\.ya?ml$|(^|\/)Dockerfile$|(^|\/)\.dockerignore$/i.test(path)),
  ],
  [
    "stock API surface stays within initial endpoints",
    includesAll(
      files.stockSystemController
        + files.stockAccountController
        + files.stockUserController
        + files.stockTradingController
        + files.stockMarketController,
      stockBackApiSurface,
    )
      && includesAll(files.stockBatchSystemController + files.stockBatchJobController, stockBatchApiSurface)
      && !includesAny(
        files.stockSystemController
          + files.stockAccountController
          + files.stockUserController
          + files.stockTradingController
          + files.stockMarketController
          + files.stockBatchSystemController
          + files.stockBatchJobController,
        [
          "/admin",
          "/watchlists",
          "/alerts",
          "/settlements/",
          "/rights",
          "/delistings",
          "/circuit-breakers",
          "/auctions",
        ],
      ),
  ],
  [
    "Spring route table contract tests cover stock API surface",
    includesAll(files.stockBackApiSurfaceTest, [
      "RequestMappingHandlerMapping",
      "getHandlerMethods()",
      "stockBackApiSurface_matchesInitialEssentialScope",
      ...stockBackApiSurfaceRoutes,
    ])
      && includesAll(files.stockBatchApiSurfaceTest, [
        "RequestMappingHandlerMapping",
        "getHandlerMethods()",
        "stockBatchInternalApiSurface_matchesInitialEssentialScope",
        ...stockBatchApiSurfaceRoutes,
      ]),
  ],
  [
    "stock system status reflects direct-first startup",
    includesAll(files.stockSystemController, [
      '"stock-back-service"',
      'List.of("accounts", "markets", "orders", "executions", "holdings", "rankings")',
      "false",
    ]),
  ],
  [
    "stock dependencies stay within initial required stack",
    includesAll(files.stockBackBuild, [
      "implementation project(':web-common-core')",
      "implementation project(':auth-common-core')",
      "spring-boot-starter-web",
      "spring-boot-starter-data-jpa",
      "spring-boot-starter-data-redis",
      "spring-cloud-starter-openfeign",
      "spring-cloud-starter-netflix-eureka-client",
    ])
      && includesAll(files.stockBatchBuild, [
        "implementation project(':web-common-core')",
        "spring-boot-starter-web",
        "spring-boot-starter-jdbc",
        "spring-boot-starter-data-redis",
        "spring-cloud-starter-netflix-eureka-client",
      ])
      && !includesAny(files.stockBackBuild + files.stockBatchBuild, [
        "spring-boot-starter-cache",
        "spring-cloud-starter-stream",
        "spring-kafka",
        "spring-rabbit",
        "spring-boot-starter-graphql",
        "spring-boot-starter-websocket",
      ])
      && !files.stockBatchBuild.includes("spring-cloud-starter-openfeign")
      && !files.stockBatchApplicationClass.includes("@EnableFeignClients"),
  ],
];

const failed = checks.filter(([, ok]) => !ok);

for (const [label, ok] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
}

if (failed.length) {
  console.error(`stock initial scope verification failed: ${failed.length} check(s)`);
  process.exit(1);
}

console.log("stock initial scope verification passed");

function read(relativePath) {
  return readFileSync(join(root, relativePath), "utf8");
}

function readTree(relativePaths) {
  return relativePaths.flatMap((relativePath) => listFiles(join(root, relativePath)))
    .filter((path) => !path.includes("/node_modules/") && !path.includes("/.next/"))
    .map((path) => readFileSync(path, "utf8"))
    .join("\n");
}

function listFiles(path) {
  if (path.includes("/.git/") || path.endsWith("/.git") || path.includes("/node_modules/") || path.includes("/.next/")) {
    return [];
  }
  const stat = statSync(path);
  if (stat.isFile()) {
    return [path];
  }
  if (!stat.isDirectory()) {
    return [];
  }
  return readdirSync(path).flatMap((entry) => listFiles(join(path, entry)));
}

function parseJavaEnum(text, enumName) {
  const match = text.match(new RegExp(`enum\\s+${enumName}\\s*\\{([\\s\\S]*?)\\}`));
  if (!match) {
    return [];
  }
  return match[1]
    .split(",")
    .map((value) => value.replace(/\/\/.*$/gm, "").trim())
    .filter(Boolean)
    .map((value) => value.replace(/;.*/, "").trim())
    .filter(Boolean);
}

function parseTsUnion(text, typeName) {
  const match = text.match(new RegExp(`type\\s+${typeName}\\s*=\\s*([^;]+);`));
  if (!match) {
    return [];
  }
  return [...match[1].matchAll(/"([^"]+)"/g)].map((item) => item[1]);
}

function includesAll(text, needles) {
  return needles.every((needle) => text.includes(needle));
}

function includesAny(text, needles) {
  return needles.some((needle) => text.includes(needle));
}

function arraysEqual(actual, expected) {
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}
