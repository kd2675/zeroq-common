#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;

const initialCorporateActionTypes = [
  "INITIAL_ISSUE",
  "PAID_IN_CAPITAL_INCREASE",
  "STOCK_SPLIT",
  "CASH_DIVIDEND",
  "BONUS_ISSUE",
  "STOCK_DIVIDEND",
  "DELISTING",
];
const adminCorporateActionTypes = initialCorporateActionTypes.filter((type) => type !== "INITIAL_ISSUE");

const deferredCorporateActionTypes = [
  "SPECIAL_DIVIDEND",
  "CAPITAL_REDUCTION",
  "REVERSE_SPLIT",
  "RIGHTS_OFFERING",
  "MERGER",
  "SPIN_OFF",
];

const allowedOrderTypes = ["LIMIT", "MARKET"];
const deferredOrderFeatures = ['"STOP_LIMIT"', '"IOC"', '"FOK"', '"GTC"', '"GTD"', '"CALL_AUCTION"', '"PRE_OPEN"', '"AFTER_HOURS"'];
const allowedMarketTypes = ["VIRTUAL_PRICE", "ORDER_BOOK"];
const allowedMarketSessionStatuses = ["OPEN", "CLOSED", "HALTED", "CIRCUIT_BREAKER"];

const files = {
  rootReadme: read("README.md"),
  corporateActionEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/StockCorporateActionType.java"),
  orderTypeEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/OrderType.java"),
  marketTypeEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/MarketType.java"),
  marketSessionStatusEnum: read("stock-back-service/src/main/java/stock/back/service/database/entity/MarketSessionStatus.java"),
  envExample: read(".env.example"),
  stockBackApplication: read("stock-back-service/src/main/resources/application.yml"),
  stockBackDevApplication: read("stock-back-service/src/main/resources/application-dev.yml"),
  stockBackProdApplication: read("stock-back-service/src/main/resources/application-prod.yml"),
  stockBackLocalDirect: read("stock-back-service/src/main/resources/application-local-direct.yml"),
  stockBackBuild: read("stock-back-service/build.gradle"),
  stockBatchApplication: read("stock-batch-service/src/main/resources/application.yml"),
  stockBatchLocalApplication: read("stock-batch-service/src/main/resources/application-local.yml"),
  stockBatchDevApplication: read("stock-batch-service/src/main/resources/application-dev.yml"),
  stockBatchProdApplication: read("stock-batch-service/src/main/resources/application-prod.yml"),
  stockBatchLocalDirect: read("stock-batch-service/src/main/resources/application-local-direct.yml"),
  cloudGatewayConfiguration: read("cloud-back-server/src/main/java/cloud/back/server/config/AdvancedGatewayConfiguration.java"),
  cloudApplication: read("cloud-back-server/src/main/resources/application.yml"),
  cloudTestApplication: read("cloud-back-server/src/test/resources/application.yml"),
  stockBatchApplicationClass: read("stock-batch-service/src/main/java/stock/batch/service/StockBatchServiceApplication.java"),
  stockBatchBuild: read("stock-batch-service/build.gradle"),
  stockBatchReadme: read("stock-batch-service/README.md"),
  stockBatchAgents: read("stock-batch-service/AGENTS.md"),
  stockBatchEnvExample: read("stock-batch-service/.env.example"),
  stockBatchArchitecture: read("stock-batch-service/docs/architecture.md"),
  stockBatchMetadataMysqlDdl: read("stock-batch-service/src/main/resources/db/schema/batch-metadata-mysql.sql"),
  stockBatchMetadataH2Ddl: read("stock-batch-service/src/main/resources/db/schema/batch-metadata-h2.sql"),
  frontApi: read("stock-front-service/app/lib/api.ts"),
  frontAuth: read("stock-front-service/app/lib/auth.ts"),
  frontStockApi: read("stock-front-service/app/lib/stock-api/core.ts"),
  frontEnvExample: read("stock-front-service/.env.example"),
  frontNextConfig: read("stock-front-service/next.config.ts"),
  frontMarketTypes: read("stock-front-service/app/types/stockMarket.ts"),
  frontTradingTypes: read("stock-front-service/app/types/stockTrading.ts"),
  frontAdmin: read("stock-front-service/app/supply-demand/admin/AdminStockEventPanel.tsx"),
  frontContractVerifier: read("scripts/verify-stock-front-contract.mjs"),
  stockSystemController: read("stock-back-service/src/main/java/stock/back/service/common/act/StockSystemController.java"),
  stockBackReadme: read("stock-back-service/README.md"),
  stockAccountController: read("stock-back-service/src/main/java/stock/back/service/trading/act/AccountController.java"),
  stockUserController: read("stock-back-service/src/main/java/stock/back/service/user/act/StockUserController.java"),
  stockTradingController: read("stock-back-service/src/main/java/stock/back/service/trading/act/TradingController.java"),
  stockMarketController: readTree(["stock-back-service/src/main/java/stock/back/service/market/act"]),
  stockBatchJobController: read("stock-batch-service/src/main/java/stock/batch/service/common/act/StockBatchJobController.java"),
  stockBatchSystemController: read("stock-batch-service/src/main/java/stock/batch/service/common/act/StockBatchSystemController.java"),
  stockBackApiSurfaceTest: read("stock-back-service/src/test/java/stock/back/service/common/config/StockBackApiSurfaceContractTest.java"),
  stockBatchApiSurfaceTest: read("stock-batch-service/src/test/java/stock/batch/service/common/config/StockBatchApiSurfaceContractTest.java"),
  stockSmoke: read("scripts/stock-smoke.sh"),
  stockH2Smoke: read("scripts/stock-h2-smoke.sh"),
  stockGatewayH2Smoke: read("scripts/stock-gateway-h2-smoke.sh"),
  stockAuthH2Smoke: read("scripts/stock-auth-h2-smoke.sh"),
  stockV4MysqlMigrationVerifier: read("scripts/verify-stock-v4-mysql-migration.sh"),
  stockV4BaselineExporter: read("scripts/export-stock-v4-baseline-readonly.sh"),
  stockV4BaselineArtifactVerifier: read(
    "scripts/verify-stock-v4-baseline-artifact.mjs",
  ),
  stockV4BaselineSqlEmitter: read(
    "scripts/emit-stock-v4-baseline-insert-sql.mjs",
  ),
  stockV4ReplaySchemaPreparer: read(
    "scripts/prepare-stock-v4-replay-schema.sh",
  ),
  stockV4ReplayBatchMetadataPreparer: read(
    "scripts/prepare-stock-v4-replay-batch-metadata.sh",
  ),
  stockV4ReplayBatchRunner: read(
    "scripts/run-stock-v4-replay-batch.sh",
  ),
  stockV4UnderwriterCheckpointDayRunner: read(
    "scripts/run-stock-v4-underwriter-checkpoint-day.sh",
  ),
  stockV4EodAdvanceRunner: read(
    "scripts/run-stock-v4-eod-to-next-open.sh",
  ),
  stockV4UnderwriterCheckpointCompletionRunner: read(
    "scripts/run-stock-v4-underwriter-checkpoint-to-completion.sh",
  ),
  stockV4ReplayCounterpartyCashRunner: read(
    "scripts/ensure-stock-v4-replay-counterparty-cash.sh",
  ),
  stockV4ReplayCheckpointCashFloorCalculator: read(
    "scripts/calculate-stock-v4-replay-checkpoint-cash-floor.sh",
  ),
  stockV4ReplaySymbolMaturityRunner: read(
    "scripts/promote-stock-v4-replay-symbol-mature.sh",
  ),
  stockV4ShareRebaseGateRunner: read(
    "scripts/run-stock-v4-share-rebase-gate.sh",
  ),
  stockV4ContractActivationGateRunner: read(
    "scripts/run-stock-v4-contract-activation-gate.sh",
  ),
  stockV4ScaledMarketTradingDayRunner: read(
    "scripts/run-stock-v4-scaled-market-trading-day.sh",
  ),
  stockV4ReplayBackRunner: read(
    "scripts/run-stock-v4-replay-back.sh",
  ),
  stockV4ReplayFixedPriceProvider: read(
    "stock-batch-service/src/main/java/stock/batch/service/marketdata/provider/ReplayFixedMarketPriceProvider.java",
  ),
  stockV4ReplayMaterializer: read(
    "scripts/materialize-stock-v4-replay-baseline.sh",
  ),
  stockV4ReplayMaterializationSql: read(
    "scripts/sql/stock-v4-replay-baseline-materialize.sql",
  ),
  stockV4ReplaySystemCustodyRepair: read(
    "scripts/repair-stock-v4-replay-system-custody-identity.sh",
  ),
  stockV4ReplayMigrationVerifier: read(
    "scripts/verify-stock-v4-replay-migration.sh",
  ),
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
  "INSERT INTO stock_auto_participant(",
  "MERGE INTO stock_virtual_market_config",
  "MERGE INTO stock_order_book_instrument",
  "MERGE INTO stock_auto_participant",
  "삼성전자",
  "'seed'",
  "stock-auto-001",
];

const canonicalMysqlDdlPath = "stock-back-service/src/main/resources/db/ddl/stock_all.sql";
const batchMysqlDdlDuplicatePath = "stock-batch-service/src/main/resources/db/ddl/stock_all.sql";
const ddlPaths = [
  canonicalMysqlDdlPath,
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

const orderSourcePaths = [
  "stock-back-service/src/main/java/stock/back/service/trading",
  "stock-batch-service/src/main/java/stock/batch/service/automarket",
  "stock-batch-service/src/main/java/stock/batch/service/execution",
  "stock-front-service/app/lib/orderSizing.ts",
  "stock-front-service/app/lib/stock-api/trading.ts",
  "stock-front-service/app/lib/validation/orderSchemas.ts",
  "stock-front-service/app/supply-demand/orders",
  "stock-front-service/app/supply-demand/OrderTicketPanel.tsx",
  "stock-front-service/app/supply-demand/useSupplyDemandOrderActions.ts",
  "stock-front-service/app/supply-demand/useSupplyDemandOrderTicketActions.ts",
  "stock-front-service/app/types/stockTrading.ts",
];

const schedulerDisableMarkers = [
  "schedulers-enabled: false",
  "simulation-clock:\n    scheduler-enabled: false",
  "signal:\n      enabled: false",
  "market-data:\n      enabled: false",
  "order-book-execution:\n      enabled: false",
  "corporate-actions:\n      enabled: false",
  "auto-market:\n      enabled: false",
  "auto-participant-cash-flow:\n      enabled: false",
  "market-close:\n      enabled: false",
  "settlement:\n      enabled: false",
];

const stockBackApiSurface = [
  '@RequestMapping("/api/stock/v1/system")',
  '@GetMapping("/status")',
  '@RequestMapping("/api/stock/v1/accounts")',
  '@GetMapping("/me")',
  '@GetMapping("/me/status")',
  '@PostMapping("/me")',
  '@DeleteMapping("/me")',
  '@PostMapping("/reconnect")',
  '@PostMapping("/admin/users/{userKey}/cash-adjustments")',
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
  '@GetMapping("/order-book-instruments/{symbol}/market-report")',
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
  '@GetMapping("/auto-market/v4/operations")',
  '@PatchMapping("/auto-market/v4/runtime")',
  '@PostMapping("/auto-market/v4/policies/scheduled")',
  '@PostMapping("/auto-market/v4/policies/neutral-cutover")',
  '@GetMapping("/auto-market/participants/overviews")',
  '@GetMapping("/auto-market/cash-flow")',
  '@PatchMapping("/auto-market/cash-flow")',
  '@PostMapping("/auto-market/cash-flow/run")',
  '@GetMapping("/batch-jobs/runtime-controls")',
  '@PatchMapping("/batch-jobs/runtime-controls/{jobName}")',
  '@PatchMapping("/auto-market/profile-configs/{profileType}")',
  '@PatchMapping("/auto-market/configs/{symbol}")',
  '@PatchMapping("/auto-market/participants/{userKey}")',
  '@DeleteMapping("/auto-market/participants/{userKey}")',
  '@PostMapping("/auto-market/participants/{userKey}/cash-adjustments")',
  '@PatchMapping("/auto-market/participants/{userKey}/symbols/{symbol}")',
];

const stockBatchApiSurface = [
  '@RequestMapping("/internal/stock-batch/v1/system")',
  '@GetMapping("/status")',
  '@RequestMapping("/internal/stock-batch/v1/jobs")',
  '@PostMapping("/market-data/refresh")',
  '@PostMapping("/order-book-execution/run")',
  '@PostMapping("/auto-participant-cash-flow/run")',
  '@GetMapping("/auto-participant-cash-flow/status")',
  '@PatchMapping("/auto-participant-cash-flow/status")',
  '@GetMapping("/runtime-controls")',
  '@PatchMapping("/runtime-controls/{jobName}")',
  '@PostMapping("/auto-market/run")',
  '@PostMapping("/portfolio-settlement/run")',
  '@PostMapping("/market-close/rollover")',
  '@PostMapping("/corporate-actions/run")',
];

const stockBackApiSurfaceRoutes = [
  "GET /api/stock/v1/system/status",
  "GET /api/stock/v1/accounts/me",
  "GET /api/stock/v1/accounts/me/status",
  "POST /api/stock/v1/accounts/me",
  "DELETE /api/stock/v1/accounts/me",
  "POST /api/stock/v1/accounts/reconnect",
  "POST /api/stock/v1/accounts/admin/users/{userKey}/cash-adjustments",
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
  "GET /api/stock/v1/markets/order-book-instruments/{symbol}/market-report",
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
  "GET /api/stock/v1/markets/auto-market/participants/overviews",
  "GET /api/stock/v1/markets/auto-market/cash-flow",
  "PATCH /api/stock/v1/markets/auto-market/cash-flow",
  "POST /api/stock/v1/markets/auto-market/cash-flow/run",
  "GET /api/stock/v1/markets/batch-jobs/runtime-controls",
  "PATCH /api/stock/v1/markets/batch-jobs/runtime-controls/{jobName}",
  "PATCH /api/stock/v1/markets/auto-market/profile-configs/{profileType}",
  "PATCH /api/stock/v1/markets/auto-market/configs/{symbol}",
  "PATCH /api/stock/v1/markets/auto-market/listing-accounts/{symbol}",
  "PATCH /api/stock/v1/markets/auto-market/participants/{userKey}",
  "DELETE /api/stock/v1/markets/auto-market/participants/{userKey}",
  "POST /api/stock/v1/markets/auto-market/participants/{userKey}/cash-adjustments",
  "PATCH /api/stock/v1/markets/auto-market/participants/{userKey}/symbols/{symbol}",
];

const stockBatchApiSurfaceRoutes = [
  "GET /internal/stock-batch/v1/system/status",
  "POST /internal/stock-batch/v1/jobs/market-data/refresh",
  "POST /internal/stock-batch/v1/jobs/order-book-execution/run",
  "POST /internal/stock-batch/v1/jobs/auto-participant-cash-flow/run",
  "GET /internal/stock-batch/v1/jobs/auto-participant-cash-flow/status",
  "PATCH /internal/stock-batch/v1/jobs/auto-participant-cash-flow/status",
  "GET /internal/stock-batch/v1/jobs/runtime-controls",
  "PATCH /internal/stock-batch/v1/jobs/runtime-controls/{jobName}",
  "POST /internal/stock-batch/v1/jobs/auto-market/run",
  "POST /internal/stock-batch/v1/jobs/portfolio-settlement/run",
  "POST /internal/stock-batch/v1/jobs/market-close/rollover",
  "POST /internal/stock-batch/v1/jobs/corporate-actions/run",
];
const currentStockBackApiSurfaceRoutes = parseExpectedApiRoutes(
  files.stockBackApiSurfaceTest,
  "/api/stock/v1",
);
const currentStockBatchApiSurfaceRoutes = parseExpectedApiRoutes(
  files.stockBatchApiSurfaceTest,
  "/internal/stock-batch/v1",
);

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
    arraysEqual(parseTsUnion(files.frontMarketTypes, "CorporateActionType"), initialCorporateActionTypes),
  ],
  [
    "front order type keeps LIMIT and MARKET only",
    arraysEqual(parseTsUnion(files.frontTradingTypes, "OrderType"), allowedOrderTypes),
  ],
  [
    "front market type keeps two market families only",
    arraysEqual(parseTsUnion(files.frontMarketTypes, "MarketType"), allowedMarketTypes),
  ],
  [
    "front market session status keeps minimal states only",
    arraysEqual(parseTsUnion(files.frontMarketTypes, "MarketSessionStatus"), allowedMarketSessionStatuses),
  ],
  [
    "admin corporate action choices cover manually registered scope and exclude automatic or deferred actions",
    includesAll(files.frontAdmin, adminCorporateActionTypes.map((type) => `value="${type}"`))
      && files.frontAdmin.includes("INITIAL_ISSUE 보관원장")
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
    "stock back owns the sole canonical MySQL business DDL",
    existsSync(join(root, canonicalMysqlDdlPath))
      && !existsSync(join(root, batchMysqlDdlDuplicatePath)),
  ],
  [
    "canonical MySQL and batch H2 keep shared order and execution scopes",
    ddlPaths.every((path) => includesAll(read(path), [
      "chk_stock_order_type_valid CHECK (CASE `order_type` WHEN 'LIMIT' THEN 1 WHEN 'MARKET' THEN 1 ELSE 0 END = 1)",
      "chk_stock_order_market_type_valid CHECK (CASE `market_type` WHEN 'VIRTUAL_PRICE' THEN 1 WHEN 'ORDER_BOOK' THEN 1 ELSE 0 END = 1)",
      "chk_stock_execution_source_valid CHECK (CASE `source` WHEN 'VIRTUAL_MARKET_PRICE' THEN 1 WHEN 'INTERNAL_ORDER_BOOK' THEN 1 ELSE 0 END = 1)",
      "chk_stock_virtual_market_status CHECK (CASE `market_status` WHEN 'OPEN' THEN 1 WHEN 'CLOSED' THEN 1 WHEN 'HALTED' THEN 1 WHEN 'CIRCUIT_BREAKER' THEN 1 ELSE 0 END = 1)",
      "chk_stock_order_book_market_status CHECK (CASE `market_status` WHEN 'OPEN' THEN 1 WHEN 'CLOSED' THEN 1 WHEN 'HALTED' THEN 1 WHEN 'CIRCUIT_BREAKER' THEN 1 ELSE 0 END = 1)",
    ])),
  ],
  [
    "stock batch uses separate Spring Batch 6 JDBC metadata schema",
    files.stockBatchBuild.includes("spring-boot-starter-batch-jdbc")
      && files.stockBatchApplication.includes("repository:\n      schema:")
      && files.stockBatchApplication.includes("datasource:\n        url: jdbc:mysql://kimd0.iptime.org:23306/STOCK_BATCH_METADATA?zeroDateTimeBehavior=convertToNull&useLegacyDatetimeCode=false&serverTimezone=Asia/Seoul&noAccessToProcedureBodies=true&useSSL=false&allowPublicKeyRetrieval=true&connectTimeout=5000&socketTimeout=60000&tcpKeepAlive=true")
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
    "main sources keep deferred corporate actions out and order surfaces keep advanced order types out",
    !includesAny(readTree(mainSourcePaths), deferredCorporateActionTypes)
      && !includesAny(readTree(orderSourcePaths), deferredOrderFeatures),
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
    "stock back does not keep a stock-batch HTTP client boundary",
    !includesAny(
      files.stockBackApplication
        + files.stockBackLocalDirect
        + files.stockBackDevApplication
        + files.stockBackProdApplication
        + readTree(["stock-back-service/src/main/java"]),
      ["batch-client:", "STOCK_BATCH_API_BASE_URL", "STOCK_BATCH_INTERNAL_TOKEN", "/internal/stock-batch/v1/jobs"],
    ),
  ],
  [
    "stock back dev/prod do not require a stock-batch HTTP boundary",
    [files.stockBackDevApplication, files.stockBackProdApplication].every((config) =>
      !includesAny(config, ["batch-client:", "STOCK_BATCH_API_BASE_URL", "STOCK_BATCH_INTERNAL_TOKEN"]),
    ),
  ],
  [
    "stock batch dev/prod require explicit internal token and disallow empty token",
    [files.stockBatchDevApplication, files.stockBatchProdApplication].every((config) =>
      includesAll(config, [
        "token: ${STOCK_BATCH_INTERNAL_TOKEN}",
        "allow-empty-token: false",
      ])
        && !includesAny(config, [
          "token: ${STOCK_BATCH_INTERNAL_TOKEN:",
          "allow-empty-token: true",
      ]),
    ),
  ],
  [
    "cloud gateway requires stock-batch internal token",
    includesAll(files.cloudApplication, [
      "token: ${STOCK_BATCH_INTERNAL_TOKEN}",
    ])
      && includesAll(files.cloudTestApplication, [
        "token: test-stock-batch-internal-token",
      ])
      && !includesAny(files.cloudApplication, [
        "token: ${STOCK_BATCH_INTERNAL_TOKEN:",
        "@Value(\"${stock.batch.internal.token:}\")",
      ]),
  ],
  [
    "cloud gateway routes stock-batch job control methods and injects internal token",
    includesAll(files.cloudGatewayConfiguration, [
      ".path(\"/internal/stock-batch/v1/jobs/**\")",
      ".and().method(HttpMethod.GET, HttpMethod.POST, HttpMethod.PATCH)",
      ".setRequestHeader(\"X-Internal-Token\", stockBatchInternalToken)",
      ".uri(\"lb://stock-batch-service\")",
    ]),
  ],
  [
    "stock gateway smoke exercises runtime control query and update",
    includesAll(files.stockSmoke, [
      "stock-batch runtime controls through gateway",
      "GET\" \"${GATEWAY_URL}/internal/stock-batch/v1/jobs/runtime-controls\"",
      "stock-batch runtime control validation through gateway",
      "PATCH\" \"${GATEWAY_URL}/internal/stock-batch/v1/jobs/runtime-controls/%20\"",
      "jobName is required",
    ]),
  ],
  [
    "stock auth and gateway smoke provide cloud stock-batch token",
    includesAll(files.stockAuthH2Smoke, [
      "STOCK_AUTH_SMOKE_BATCH_TOKEN=",
      "export STOCK_BATCH_INTERNAL_TOKEN=",
    ])
      && includesAll(files.stockGatewayH2Smoke, [
        "STOCK_GATEWAY_H2_BATCH_TOKEN=",
        "export STOCK_BATCH_INTERNAL_TOKEN=",
      ]),
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
      ])
      && includesAll(files.stockBatchLocalApplication, [
        "token: ${STOCK_BATCH_INTERNAL_TOKEN:local-stock-batch-internal-token}",
        "allow-empty-token: false",
      ])
      && !files.stockBatchLocalApplication.includes("allow-empty-token: true"),
  ],
  [
    "stock local docs and examples match local-direct batch port and token",
    includesAll(files.envExample, [
      "STOCK_BATCH_INTERNAL_TOKEN=local-stock-batch-internal-token",
      "STOCK_BATCH_URL=http://localhost:20481",
    ])
      && includesAll(files.rootReadme, [
        "`20481` (`local/local-direct/dev`)",
        "기본 `local-direct`는 `local-stock-batch-internal-token`을 사용하고 `20481` 포트로 뜹니다.",
        "빈 token 허용은 테스트/smoke 편의 profile에서만 켭니다.",
      ])
      && includesAll(files.stockBatchReadme, [
        "| `local-direct` | `20481` |",
        "기본 `local-direct`는 `local-stock-batch-internal-token`을 사용하고 `20481` 포트로 뜹니다.",
        "빈 token 허용은 테스트/smoke 편의 profile에서만 켭니다.",
      ])
      && includesAll(files.stockBatchAgents, [
        "local/local-direct/dev 20481",
        "기본 `local-direct`는 `local-stock-batch-internal-token`을 사용합니다.",
      ])
      && includesAll(files.stockBatchEnvExample, [
        "STOCK_BATCH_INTERNAL_TOKEN=local-stock-batch-internal-token",
      ])
      && includesAll(files.stockBackReadme, [
        "| `local-direct` | `20480` |",
        "`STOCK_AUTH_BASE_URL`",
        "http://localhost:9000",
        "stock-back은 stock-batch 내부 HTTP API를 호출하지 않고",
      ])
      && includesAll(files.stockSmoke, [
        'STOCK_BATCH_URL="${STOCK_BATCH_URL:-http://localhost:20481}"',
        'STOCK_BATCH_INTERNAL_TOKEN="${STOCK_BATCH_INTERNAL_TOKEN:-local-stock-batch-internal-token}"',
      ])
      && !includesAny(files.rootReadme + files.stockBatchReadme + files.stockBatchAgents, [
        "local-direct` | `30481",
        "local-direct/test 30481",
        "local-direct 30481",
        "`local`/`test` profile에서만",
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
    "isolated V4 MySQL verifier protects production and checks exact numeric targets",
    includesAll(files.stockV4MysqlMigrationVerifier, [
      "^STOCK_V4_VERIFY_[A-Za-z0-9_]+$",
      "verification schema already exists and will not be overwritten",
      "DROP DATABASE IF EXISTS",
      "prepare_legacy_v3_fixture",
      "stock_order/stock_execution index fingerprint unchanged",
      "8|577289815|402369898|44594000000000.00|3699844",
      "existing seven-symbol intermediate target",
      "7|505128588|366289285|39023153275600.00|3237364",
      "symbol share and market-capitalization arithmetic",
      "0|0|44594000000000.00",
      "derived target reference turnover is inside the contract band",
      "285802591950.00|1",
      "150|15000|100.0000|16006366331295.49|0.35893542",
      "retired and disabled legacy V3 policy",
      "neutral V4 draft policy count",
    ])
      && !files.stockV4MysqlMigrationVerifier.includes("DROP DATABASE IF EXISTS STOCK_SERVICE")
      && !files.stockV4MysqlMigrationVerifier.includes("USE STOCK_SERVICE"),
  ],
  [
    "V4 baseline exporter is immutable, read-only, and preserves replay transformations",
    includesAll(files.stockV4BaselineExporter, [
      'BASELINE_CLOSE_RUN_ID=259',
      'BASELINE_BUSINESS_DATE="2027-02-09"',
      "SET TRANSACTION READ ONLY",
      "START TRANSACTION WITH CONSISTENT SNAPSHOT",
      "baseline market aggregate",
      "7|26650000|19325000|333820000000.00|24108|282128590.00",
      "baseline holding snapshot reconciliation",
      "baseline account reconciliation",
      "'snapshotReservedQuantity'",
      "'replayReservedQuantity', 0",
      "'postCancelCash'",
      "'ACCOUNT_CASH_FLOW'",
      "'SECURITY_ALLOCATION'",
      "'ORDER_STRATEGY_ORIGIN'",
      "'operationalReplayRule'",
      "export directory already exists and will not be overwritten",
      "baseline.ndjson.tsv",
      "SHA256SUMS",
    ])
      && !/\b(?:INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|REPLACE)\b/i.test(
        files.stockV4BaselineExporter,
      ),
  ],
  [
    "V4 baseline artifact verifier pins economic rows and the known broken intent basis",
    includesAll(files.stockV4BaselineArtifactVerifier, [
      "expectedSectionCounts",
      '"artifact version", metadata.artifactVersion, 6',
      '["ACCOUNT_SNAPSHOT", 179]',
      '["ACCOUNT_CASH_FLOW", 4649]',
      '["HOLDING_SNAPSHOT", 395]',
      '["CORPORATE_ACTION", 8]',
      '["CORPORATE_ACTION_ENTITLEMENT", 72]',
      '["PROFILE_CONFIG", 27]',
      '["AUTO_MARKET_CONFIG", 7]',
      '["LIQUIDITY_TRANSITION", 7]',
      '["SECURITY_ALLOCATION", 25]',
      '["MARKET_REFERENCE_VOLUME", 14]',
      '["UNDERWRITING_DAILY_STATE", 8]',
      '["LIQUIDITY_DAILY_STATE", 41]',
      '["MARKET_POLICY", 32]',
      '["AUTO_POLICY", 1]',
      '["ORDER", 799]',
      '["ORDER_STRATEGY_ORIGIN", 719]',
      '["EXECUTION", 130]',
      '["AUTO_INTENT", 16]',
      "26_650_000n",
      "19_325_000n",
      "333_820_000_000n",
      "24_108n",
      "59_203n",
      '["DEMO006", 621_875n]',
      "37_183_802n",
      "account cash-flow net equals post-cancel cash",
      "initial issue ledger quantity",
      "order strategy origin references",
      "baseline active intent count",
      "54_283n",
      "assertNoSensitiveKeys",
    ]),
  ],
  [
    "V4 replay loader stages the verified artifact without local-infile or production writes",
    includesAll(files.stockV4BaselineSqlEmitter, [
      "INSERT INTO stock_v4_replay_artifact_line",
      "Buffer.from(value, \"utf8\").toString(\"hex\")",
      "invalid TSV structure",
    ])
      && includesAll(files.stockV4ReplaySchemaPreparer, [
        "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
        "replay schema already exists and will not be overwritten",
        "verify-stock-v4-baseline-artifact.mjs",
        "emit-stock-v4-baseline-insert-sql.mjs",
        "artifact line count",
        "7370",
        "6|259|2027-02-09",
      ])
      && !files.stockV4ReplaySchemaPreparer.includes("SET GLOBAL local_infile")
      && !files.stockV4ReplaySchemaPreparer.includes("DROP DATABASE IF EXISTS STOCK_SERVICE"),
  ],
  [
    "V4 replay materialization preserves baseline economics and retires V3 runtime",
    includesAll(
      files.stockV4ReplayMaterializer
        + files.stockV4ReplayMaterializationSql,
      [
        "stock_v4_replay_materialization_audit",
        "6|259|2027-02-09|7370",
        "7|26650000|19325000|333820000000.00|24108|282128590.00",
        "395|26650000|59203",
        "179|288537382484.00|151|150",
        "4649|288537382484.00|8|72|7|7|25|37183802|14|8|41|719",
        "materialized underwriting allocation reconciliation",
        "materialized system-custody runtime identity",
        "WHEN 'SYSTEM_CUSTODY' THEN 'SYSTEM_CUSTODY'",
        "WHEN 'SYSTEM_CUSTODY' THEN 'SYSTEM_CUSTODY:DEFAULT'",
        "stock_account_cash_flow",
        "stock_security_allocation_ledger",
        "stock_order_strategy_origin",
        "DEMO004:4974998|DEMO005:1492500|DEMO006:621875|DEMO007:198999",
        "799|130|65|24108|282128590.00|16|13|54283",
        "'V3'",
        "'RETIRED'",
        "FALSE",
        "'V4'",
      ],
    )
      && !files.stockV4ReplayMaterializer.includes("--database=STOCK_SERVICE")
      && !files.stockV4ReplayMaterializationSql.includes("USE STOCK_SERVICE"),
  ],
  [
    "V4 replay system-custody repair is isolated, quiescent, and D8 pre-listing only",
    includesAll(files.stockV4ReplaySystemCustodyRepair, [
      "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
      "D8 pre-listing reconstruction boundary",
      "quiescent replay ledgers",
      "single active system-custody role",
      "canonical system-custody identity conflicts",
      "participant_code = 'SYSTEM_CUSTODY'",
      "self_trade_group_id = 'SYSTEM_CUSTODY:DEFAULT'",
      "repaired only the isolated replay system-custody runtime identity",
    ])
      && !files.stockV4ReplaySystemCustodyRepair.includes("STOCK_SERVICE")
      && !files.stockV4ReplaySystemCustodyRepair.includes(
        "DROP DATABASE",
      ),
  ],
  [
    "V4 replay services isolate both schemas and one-lever EOD transitions",
    includesAll(files.stockV4ReplayBatchMetadataPreparer, [
      "^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$",
      "replay batch schema already exists and will not be overwritten",
      "batch-metadata-mysql.sql",
      "batch metadata table count",
      "batch metadata sequence basis",
      "operating STOCK_BATCH_METADATA was not queried or changed",
    ])
      && !files.stockV4ReplayBatchMetadataPreparer.includes(
        "--database=STOCK_BATCH_METADATA",
      )
      && !files.stockV4ReplayBatchMetadataPreparer.includes(
        "DROP DATABASE IF EXISTS STOCK_BATCH_METADATA",
      )
      && includesAll(files.stockV4ReplayBatchRunner, [
        "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
        "^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$",
        "business and batch metadata schemas must be different",
        "STOCK_BATCH_SCHEDULERS_ENABLED=false",
        "STOCK_SIMULATION_CLOCK_SCHEDULER_ENABLED=false",
        "STOCK_BATCH_SIGNAL_ENABLED=false",
        "STOCK_BATCH_ORDER_BOOK_EXECUTION_ENABLED=false",
        "STOCK_BATCH_AUTO_MARKET_ENABLED=false",
        "STOCK_BATCH_POST_CLOSE_COORDINATOR_ENABLED=false",
        "all automatic business schedulers, signal polling, and clock mutation will be disabled",
        "--eod-transition",
        "STOCK_V4_REPLAY_ALLOW_EOD_TRANSITION",
        "STOCK_BATCH_MARKET_DATA_PROVIDER=replay-fixed",
        "--checkpoint-trading",
        "STOCK_V4_REPLAY_ALLOW_CHECKPOINT_TRADING",
        "only the simulation clock heartbeat is scheduled; all business jobs remain manual",
        "STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_SCHEDULER_ENABLED=false",
        "STOCK_BATCH_MARKET_CLOSE_SETTLEMENT_DELAY_SIMULATION_MINUTES=0",
        "STOCK_BATCH_ISSUE_UNDERWRITER_DAILY_SUBMISSION_RATE",
        "STOCK_BATCH_ISSUE_UNDERWRITER_SINGLE_ORDER_RATE",
        "STOCK_BATCH_ISSUE_UNDERWRITER_DAILY_ORDER_LIMIT",
        "--scaled-market-trading",
        "STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_TRADING",
        "single active scaled-market contract",
        "V3 live and V4 active policy counts",
        "quiescent scaled-market opening ledgers",
        "WHERE status = 'ACTIVE'",
        "STOCK_BATCH_EXECUTION_READY_SYMBOL_QUEUE_TYPE=memory",
        "STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_TYPE=memory",
        "STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_ENABLED=true",
        "STOCK_BATCH_LIQUIDITY_PROVIDER_MARKET_ENABLED=true",
        "STOCK_BATCH_INSTITUTION_MARKET_ENABLED=true",
      ])
      && includesAll(files.stockV4ReplayBackRunner, [
        "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
        "business replay schema cannot be a batch metadata schema",
        "both read and write pools will use the same isolated replay schema",
        "DATABASE_DATASOURCE_PUB_MASTER_URL",
        "DATABASE_DATASOURCE_PUB_SLAVE1_URL",
        "STOCK_PRICE_STREAM_REDIS_LISTENER_ENABLED=false",
      ])
      && includesAll(files.stockV4ReplayFixedPriceProvider, [
        'havingValue = "replay-fixed"',
        "previousPrice",
        "simulationClockService.currentMarketDateTime()",
      ])
      && !files.stockV4ReplayBatchRunner.includes("/STOCK_SERVICE?")
      && !files.stockV4ReplayBatchRunner.includes("/STOCK_BATCH_METADATA?")
      && !files.stockV4ReplayBackRunner.includes("/STOCK_SERVICE?"),
  ],
  [
    "V4 scaled-market day runner preserves a full guarded regular session",
    includesAll(files.stockV4ScaledMarketTradingDayRunner, [
      "STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_DAY",
      "STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_TRADING",
      "stopped 06:00 REGULAR state at the unchanged clock speed",
      'batch_mode_argument="--scaled-market-trading"',
      'batch_mode_argument="--resume-scaled-market-trading"',
      '--check-only "${batch_mode_argument}"',
      "trading date advanced unexpectedly",
      "scaled-market regular session reached close",
      "assert_intraday_flow_invariants",
      "targetBreaches|sideImbalance|invalidReservations",
      "scaled-market batch shutdown did not preserve stopped close state",
      "scaled-market stopped close state simulationDateTime",
      "orders=count|quantity|filled|cancelled",
      "executions=rows|buyQuantity|buyTurnover",
      "intents=count|completed|active",
      "scaled-market regular day stopped for EOD",
    ])
      && !files.stockV4ScaledMarketTradingDayRunner.includes("STOCK_SERVICE")
      && !files.stockV4ScaledMarketTradingDayRunner.includes("DROP DATABASE"),
  ],
  [
    "V4 underwriting replay runners serialize one checkpoint and fail closed",
    includesAll(files.stockV4UnderwriterCheckpointDayRunner, [
      "STOCK_V4_REPLAY_ALLOW_CHECKPOINT_DAY",
      "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
      "expected exactly one positive open contract sell",
      "counterparty cash capacity is insufficient",
      "DAILY_SUBMISSION_LIMIT_REACHED",
      "FILLED_TARGET_REACHED",
      "openOrders=0 reserved=0",
    ])
      && includesAll(files.stockV4EodAdvanceRunner, [
        "STOCK_V4_REPLAY_ALLOW_EOD_ADVANCE",
        "PORTFOLIO_SETTLED",
        "NEXT_SIMULATION_DAY_START",
        "--stop-after-reports",
        "stopped after current-day reports",
        "NEXT_PREOPEN_TRANSFORM_START",
        "NEXT_AUTO_MARKET_PREPARATION_START",
        "NEXT_MARKET_OPEN",
        "resumes committed PRE_OPEN phase",
        "business-date promotion",
      ])
      && includesAll(files.stockV4UnderwriterCheckpointCompletionRunner, [
        "STOCK_V4_REPLAY_ALLOW_CHECKPOINT_COMPLETION",
        "stock-v4-underwriter-completion-",
        "business and batch replay schemas must be different",
        "wait_for_regular_clock_stop",
        "CLOCK_STOP_TIMEOUT_SECONDS",
        "checkpoint simulation clock stopped",
        "checkpoint exceeded trading-day guard",
        "is_terminal_checkpoint_lifecycle",
        '"COMPLETED"',
        "terminal lifecycle",
        "single numeric checkpoint fully completed",
      ])
      && includesAll(files.stockV4ReplayCounterpartyCashRunner, [
        "STOCK_V4_REPLAY_ALLOW_COUNTERPARTY_FUNDING",
        "STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH",
        "counterparty funding requires stopped aligned REGULAR state",
        "participant_category",
        "MANUAL_PARTICIPANT",
        "ADMIN_DEPOSIT",
        "/cash-adjustments",
        "exact_audit_rows",
      ])
      && includesAll(files.stockV4ReplayCheckpointCashFloorCalculator, [
        "exactly one current ACTIVE or next SCHEDULED checkpoint policy is required",
        "requiredCheckpointQuantity",
        "dailySubmissionQuantityLimit",
        "singleOrderQuantityLimit",
        "dailyOrderLimit",
        "checkpoint-day BUY price would violate the dynamic Korean tick",
        "requiredAvailableCash=",
      ])
      && includesAll(files.stockV4ReplaySymbolMaturityRunner, [
        "STOCK_V4_REPLAY_ALLOW_MATURITY_PROMOTION",
        "maturity promotion requires stopped PRE_OPEN/REPORTS_AGGREGATED state",
        "CAST(instrument.enabled AS UNSIGNED)",
        "observedDistributedShareRate",
        "maturity already promoted and reconciled",
        "underwriter_contract_count",
        "active_policy_count",
        "/promote-mature",
        "exact_audit_rows",
        "symbol maturity promoted",
      ])
      && !files.stockV4UnderwriterCheckpointDayRunner.includes(
        "--database=STOCK_SERVICE",
      )
      && !files.stockV4UnderwriterCheckpointCompletionRunner.includes(
        "--database=STOCK_SERVICE",
      )
      && !files.stockV4ReplayCounterpartyCashRunner.includes(
        "--database=STOCK_SERVICE",
      )
      && !files.stockV4ReplayCheckpointCashFloorCalculator.includes(
        "--database=STOCK_SERVICE",
      )
      && !files.stockV4ReplaySymbolMaturityRunner.includes(
        "--database=STOCK_SERVICE",
      ),
  ],
  [
    "V4 materialized replay migration is idempotent and pins every shortage target",
    includesAll(files.stockV4ReplayMigrationVerifier, [
      "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
      "materialized baseline marker",
      "6|259|2027-02-09|7370",
      "baseline business data unchanged after migration",
      "stock_order/stock_execution index fingerprint unchanged",
      "for attempt in 1 2",
      "8|577289815|402369898|44594000000000.00|3699844",
      "256330000000.00|383210000000.00",
      "all existing and new symbol targets",
      "existing seven-symbol intermediate target",
      "7|505128588|366289285|39023153275600.00|3237364",
      "symbol share and market-capitalization arithmetic",
      "0|0|44594000000000.00",
      "derived target reference turnover is inside the contract band",
      "285802591950.00|1",
      "150|15000|100.0000|16006366331295.49|0.35893542",
      "non-runnable historical V3 policy",
      "neutral V4 draft policy",
      "stock_v4_replay_migration_audit",
    ])
      && !files.stockV4ReplayMigrationVerifier.includes("DROP DATABASE")
      && !files.stockV4ReplayMigrationVerifier.includes("USE STOCK_SERVICE"),
  ],
  [
    "V4 structural rebase gates pin all numeric shortages and stop between atomic stages",
    includesAll(files.stockV4ShareRebaseGateRunner, [
      "STOCK_V4_REPLAY_ALLOW_SHARE_REBASE_GATE",
      "^STOCK_V4_REPLAY_[A-Za-z0-9_]+$",
      "^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$",
      "SHARE_STRUCTURE",
      "REPORTS_AGGREGATED",
      "DEFERRED",
      "STOCK_BATCH_POST_CLOSE_RETRY_BASE_SECONDS",
      "share-rebase target issued shares",
      "share-rebase target tradable shares",
      "share-rebase target market capitalization",
      "share-rebase per-symbol contract target mismatches",
      "share-rebase mature symbol targets",
      "applied per-symbol instrument share mismatches",
      "applied holding-plan mismatches",
      "applied per-symbol holding reconciliation failures",
      "share-rebase gate complete",
    ])
      && includesAll(files.stockV4ContractActivationGateRunner, [
        "STOCK_V4_REPLAY_ALLOW_CONTRACT_ACTIVATION_GATE",
        "PRICE_CAPITAL",
        "MARKET_ROLE_CAPACITY",
        "scheduled scaled-market contract",
        "population contract",
        "role-capacity automatic-market plan count",
        "role-capacity automatic-market target maximum total",
        "role-capacity automatic-market ratio or symbol mismatches",
        "role-capacity LP plan count",
        "role-capacity institution mandate count",
        "STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER",
        "STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER",
        "price-capital per-symbol contract target mismatches",
        "role-capacity LP per-symbol target mismatches",
        "applied per-symbol economic target mismatches",
        "applied market capitalization",
        "price-capital account cash mismatch count",
        "price-capital account holding-value mismatch count",
        "price-capital cohort AUM mismatch count",
        "price-capital cash-flow audit row count",
        "price-capital cash-flow audit mismatches",
        "price-capital planned cash-flow account mismatches",
        "automatic-market role-capacity mismatch count",
        "LP role-capacity mismatch count",
        "institution role-capacity mismatch count",
        "live V3 policy count",
        "active V4 policy count",
        "scaled-market contract activation complete",
      ])
      && !files.stockV4ShareRebaseGateRunner.includes(
        "--database=STOCK_SERVICE",
      )
      && !files.stockV4ContractActivationGateRunner.includes(
        "--database=STOCK_SERVICE",
      ),
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
      ...currentStockBackApiSurfaceRoutes,
    ])
      && includesAll(files.stockBatchApiSurfaceTest, [
        "RequestMappingHandlerMapping",
        "getHandlerMethods()",
        "stockBatchInternalApiSurface_matchesInitialEssentialScope",
        ...currentStockBatchApiSurfaceRoutes,
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
        "spring-boot-starter-batch-jdbc",
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

function parseExpectedApiRoutes(text, pathPrefix) {
  return [...text.matchAll(/"((?:GET|POST|PATCH|PUT|DELETE) (\/[^"]+))"/g)]
    .map((match) => match[1])
    .filter((route) => route.includes(` ${pathPrefix}`));
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
