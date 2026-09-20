// A small, strict CSV reader for the legacy import.
//
// Handles what spreadsheet exports actually produce: a UTF-8 byte order
// mark, quoted fields containing commas or newlines, doubled quotes
// inside a quoted field, and CRLF line endings.

/** Splits CSV text into rows of raw string cells. */
export function parseCsv(text) {
  // Excel and many exporters put a byte order mark first. Left in place
  // it becomes part of the first column's name.
  const input = text.replace(/^﻿/, "");

  const rows = [];
  let row = [];
  let cell = "";
  let inQuotes = false;
  let cellWasQuoted = false;

  for (let i = 0; i < input.length; i++) {
    const character = input[i];

    if (inQuotes) {
      if (character === '"') {
        if (input[i + 1] === '"') {
          cell += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell += character;
      }
      continue;
    }

    if (character === '"' && cell === "") {
      inQuotes = true;
      cellWasQuoted = true;
    } else if (character === ",") {
      row.push(cell);
      cell = "";
      cellWasQuoted = false;
    } else if (character === "\n" || character === "\r") {
      if (character === "\r" && input[i + 1] === "\n") i++;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
      cellWasQuoted = false;
    } else {
      cell += character;
    }
  }

  if (inQuotes) throw new Error("The file ends inside a quoted value — a closing quote is missing.");
  if (cell !== "" || cellWasQuoted || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }

  // Trailing blank lines are normal at the end of a file.
  return rows.filter((cells) => !(cells.length === 1 && cells[0].trim() === ""));
}

/**
 * Reads a CSV into objects, keeping only the columns asked for.
 * Returns the rows, and the names of any columns that were ignored, so
 * nothing is dropped silently.
 */
export function readCsvRows(text, { fileName, required, optional = [] }) {
  const rows = parseCsv(text);
  if (rows.length === 0) throw new Error(`${fileName} is empty.`);

  const headers = rows[0].map((header) => header.trim());
  const wanted = new Set([...required, ...optional]);

  const missing = required.filter((column) => !headers.includes(column));
  if (missing.length > 0) {
    throw new Error(`${fileName} is missing the column(s): ${missing.join(", ")}`);
  }

  const ignored = headers.filter((header) => header !== "" && !wanted.has(header));

  const records = rows.slice(1).map((cells, index) => {
    if (cells.length !== headers.length) {
      throw new Error(
        `${fileName} line ${index + 2} has ${cells.length} value(s) but the header has ${headers.length}.`,
      );
    }
    const record = {};
    headers.forEach((header, position) => {
      if (wanted.has(header)) record[header] = cells[position].trim();
    });
    for (const column of wanted) {
      if (!(column in record)) record[column] = "";
    }
    return record;
  });

  return { records, ignored };
}
