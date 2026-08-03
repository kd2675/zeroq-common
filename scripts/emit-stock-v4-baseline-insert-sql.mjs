#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const artifactPath = process.argv[2];
if (!artifactPath) {
  fail(
    "usage: node scripts/emit-stock-v4-baseline-insert-sql.mjs "
      + "<baseline.ndjson.tsv>",
  );
}

const rows = readFileSync(resolve(artifactPath), "utf8")
  .split(/\r?\n/u)
  .filter((line) => line.length > 0)
  .map(parseLine);

const batchSize = 100;
process.stdout.write("START TRANSACTION;\n");
for (let offset = 0; offset < rows.length; offset += batchSize) {
  const batch = rows.slice(offset, offset + batchSize);
  process.stdout.write(
    "INSERT INTO stock_v4_replay_artifact_line("
      + "section_name, row_key, payload_json"
      + ") VALUES\n",
  );
  process.stdout.write(
    batch.map((row) => (
      `(${utf8Hex(row.section)},`
      + `${utf8Hex(row.key)},`
      + `CAST(${utf8Hex(JSON.stringify(row.payload))} AS JSON))`
    )).join(",\n"),
  );
  process.stdout.write(";\n");
}
process.stdout.write("COMMIT;\n");

function parseLine(line, index) {
  const firstTab = line.indexOf("\t");
  const secondTab = line.indexOf("\t", firstTab + 1);
  if (firstTab <= 0 || secondTab <= firstTab + 1) {
    fail(`invalid TSV structure at line ${index + 1}`);
  }
  const section = line.slice(0, firstTab);
  const key = line.slice(firstTab + 1, secondTab);
  const payloadText = line.slice(secondTab + 1);
  try {
    return {
      section,
      key,
      payload: JSON.parse(payloadText),
    };
  } catch (error) {
    fail(`invalid JSON at line ${index + 1}: ${error.message}`);
  }
}

function utf8Hex(value) {
  return `CONVERT(X'${Buffer.from(value, "utf8").toString("hex")}' USING utf8mb4)`;
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}
