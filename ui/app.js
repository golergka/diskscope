const fileInput = document.getElementById("json-file");
const treemapElement = document.getElementById("treemap");
const emptyState = document.getElementById("empty-state");
const zoomOutButton = document.getElementById("zoom-out");
const resetViewButton = document.getElementById("reset-view");
const scanMetricsElement = document.getElementById("scan-metrics");
const selectionMetricsElement = document.getElementById("selection-metrics");
const errorSummaryElement = document.getElementById("error-summary");
const errorListElement = document.getElementById("error-list");

const SNAPSHOT_MAGIC = "DSCPBIN1";
const ROOT_ID = 0;

const state = {
  dataset: null,
  currentNodeId: ROOT_ID,
  selectedNodeId: ROOT_ID,
};

fileInput.addEventListener("change", async (event) => {
  const file = event.target.files?.[0];
  if (!file) {
    return;
  }

  try {
    const bytes = await file.arrayBuffer();
    const dataset = tryLoadDataset(bytes);
    if (!dataset) {
      showLoadError("Unsupported file. Use a diskscope binary snapshot or JSON.");
      return;
    }

    state.dataset = dataset;
    state.currentNodeId = ROOT_ID;
    state.selectedNodeId = ROOT_ID;

    renderScanMetrics();
    renderSelectionMetrics();
    renderErrors();
    renderTreemap();
    updateButtons();
  } catch (error) {
    showLoadError(`Failed to load file: ${String(error)}`);
  }
});

zoomOutButton.addEventListener("click", () => {
  const dataset = state.dataset;
  if (!dataset) {
    return;
  }

  const parent = dataset.parentOf(state.currentNodeId);
  if (parent == null) {
    return;
  }

  state.currentNodeId = parent;
  state.selectedNodeId = parent;
  renderTreemap();
  renderSelectionMetrics();
  updateButtons();
});

resetViewButton.addEventListener("click", () => {
  if (!state.dataset) {
    return;
  }

  state.currentNodeId = ROOT_ID;
  state.selectedNodeId = ROOT_ID;
  renderTreemap();
  renderSelectionMetrics();
  updateButtons();
});

window.addEventListener(
  "resize",
  debounce(() => {
    if (state.dataset) {
      renderTreemap();
    }
  }, 120)
);

function tryLoadDataset(arrayBuffer) {
  const bytes = new Uint8Array(arrayBuffer);
  const magic = decodeUtf8(bytes.subarray(0, 8));
  if (magic === SNAPSHOT_MAGIC) {
    return parseBinarySnapshot(arrayBuffer);
  }

  const text = decodeUtf8(bytes);
  try {
    const scan = JSON.parse(text);
    return parseJsonFallback(scan);
  } catch (_error) {
    return null;
  }
}

function parseBinarySnapshot(arrayBuffer) {
  const view = new DataView(arrayBuffer);
  const bytes = new Uint8Array(arrayBuffer);

  let offset = 0;
  const magic = decodeUtf8(bytes.subarray(offset, offset + 8));
  offset += 8;
  if (magic !== SNAPSHOT_MAGIC) {
    throw new Error(`invalid snapshot magic '${magic}'`);
  }

  const version = readU32(view, offset);
  offset += 4;
  if (version !== 1) {
    throw new Error(`unsupported snapshot version '${version}'`);
  }

  const recordSize = readU32(view, offset);
  offset += 4;
  if (recordSize !== 44) {
    throw new Error(`unsupported node record size '${recordSize}'`);
  }

  const nodeCount = readU64AsNumber(view, offset);
  offset += 8;
  const childIndexCount = readU64AsNumber(view, offset);
  offset += 8;
  const topCount = readU64AsNumber(view, offset);
  offset += 8;
  const errorCount = readU64AsNumber(view, offset);
  offset += 8;
  const nameBlobLen = readU64AsNumber(view, offset);
  offset += 8;
  const rootPathLen = readU64AsNumber(view, offset);
  offset += 8;

  const totalSizeBytes = readU64AsNumber(view, offset);
  offset += 8;
  const directories = readU64AsNumber(view, offset);
  offset += 8;
  const files = readU64AsNumber(view, offset);
  offset += 8;
  const elapsedMs = readU64AsNumber(view, offset);
  offset += 8;
  const errors = readU64AsNumber(view, offset);
  offset += 8;
  const ignored = readU64AsNumber(view, offset);
  offset += 8;
  const skippedHidden = readU64AsNumber(view, offset);
  offset += 8;
  const skippedSymlink = readU64AsNumber(view, offset);
  offset += 8;
  const skippedOther = readU64AsNumber(view, offset);
  offset += 8;

  const rootPathBytes = bytes.subarray(offset, offset + rootPathLen);
  const rootPath = decodeUtf8(rootPathBytes);
  offset += rootPathLen;

  const parent = new Int32Array(nodeCount);
  const firstChild = new Uint32Array(nodeCount);
  const childCount = new Uint32Array(nodeCount);
  const nameOffset = new Uint32Array(nodeCount);
  const nameLen = new Uint32Array(nodeCount);
  const sizeBytes = new Array(nodeCount);
  const fileCount = new Array(nodeCount);
  const dirCount = new Array(nodeCount);

  for (let i = 0; i < nodeCount; i += 1) {
    const parentRaw = readU32(view, offset);
    offset += 4;
    parent[i] = parentRaw === 0xffffffff ? -1 : parentRaw;
    firstChild[i] = readU32(view, offset);
    offset += 4;
    childCount[i] = readU32(view, offset);
    offset += 4;
    nameOffset[i] = readU32(view, offset);
    offset += 4;
    nameLen[i] = readU32(view, offset);
    offset += 4;
    sizeBytes[i] = readU64AsNumber(view, offset);
    offset += 8;
    fileCount[i] = readU64AsNumber(view, offset);
    offset += 8;
    dirCount[i] = readU64AsNumber(view, offset);
    offset += 8;
  }

  const childIndex = new Uint32Array(childIndexCount);
  for (let i = 0; i < childIndexCount; i += 1) {
    childIndex[i] = readU32(view, offset);
    offset += 4;
  }

  const topIndex = new Uint32Array(topCount);
  for (let i = 0; i < topCount; i += 1) {
    topIndex[i] = readU32(view, offset);
    offset += 4;
  }

  const names = bytes.slice(offset, offset + nameBlobLen);
  offset += nameBlobLen;

  const errorSamples = [];
  for (let i = 0; i < errorCount; i += 1) {
    const pathLen = readU32(view, offset);
    offset += 4;
    const messageLen = readU32(view, offset);
    offset += 4;

    const path = decodeUtf8(bytes.subarray(offset, offset + pathLen));
    offset += pathLen;
    const message = decodeUtf8(bytes.subarray(offset, offset + messageLen));
    offset += messageLen;

    errorSamples.push({ path, message });
  }

  const nameCache = new Map();

  return {
    kind: "binary",
    rootPath,
    totalSizeBytes,
    directories,
    files,
    elapsedMs,
    errors,
    ignored,
    skippedHidden,
    skippedSymlink,
    skippedOther,
    skippedTotal: skippedHidden + skippedSymlink + skippedOther + ignored,
    errorSamples,
    topIndex,

    nodeCount,
    parent,
    firstChild,
    childCount,
    childIndex,
    sizeBytes,
    fileCount,
    dirCount,
    nameOffset,
    nameLen,
    names,

    nameOf(nodeId) {
      const cached = nameCache.get(nodeId);
      if (cached) {
        return cached;
      }
      const start = nameOffset[nodeId];
      const end = start + nameLen[nodeId];
      const name = decodeUtf8(names.subarray(start, end));
      nameCache.set(nodeId, name);
      return name;
    },

    parentOf(nodeId) {
      const value = parent[nodeId];
      return value < 0 ? null : value;
    },

    childrenOf(nodeId) {
      const start = firstChild[nodeId];
      const count = childCount[nodeId];
      const children = new Array(count);
      for (let i = 0; i < count; i += 1) {
        children[i] = childIndex[start + i];
      }
      children.sort((left, right) => sizeBytes[right] - sizeBytes[left]);
      return children;
    },

    sizeOf(nodeId) {
      return sizeBytes[nodeId] ?? 0;
    },

    fileCountOf(nodeId) {
      return fileCount[nodeId] ?? 0;
    },

    dirCountOf(nodeId) {
      return dirCount[nodeId] ?? 0;
    },

    childCountOf(nodeId) {
      return childCount[nodeId] ?? 0;
    },
  };
}

function parseJsonFallback(scan) {
  if (!Array.isArray(scan.tree) || scan.tree.length === 0) {
    throw new Error("JSON fallback requires --json-tree output");
  }

  const nodeCount = scan.tree.length;
  const parent = new Int32Array(nodeCount);
  const firstChild = new Uint32Array(nodeCount);
  const childCount = new Uint32Array(nodeCount);
  const sizeBytes = new Array(nodeCount);
  const fileCount = new Array(nodeCount);
  const dirCount = new Array(nodeCount);
  const names = new Array(nodeCount);

  for (const node of scan.tree) {
    const id = Number(node.id);
    parent[id] = node.parent == null ? -1 : Number(node.parent);
    sizeBytes[id] = toNonNegative(node.size_bytes);
    fileCount[id] = toNonNegative(node.file_count);
    dirCount[id] = toNonNegative(node.dir_count);
    names[id] = String(node.name ?? `node-${id}`);
  }

  for (let id = 1; id < nodeCount; id += 1) {
    const p = parent[id];
    if (p >= 0) {
      childCount[p] += 1;
    }
  }

  let cursor = 0;
  for (let id = 0; id < nodeCount; id += 1) {
    firstChild[id] = cursor;
    cursor += childCount[id];
  }

  const childIndex = new Uint32Array(cursor);
  const writeOffsets = firstChild.slice();
  for (let id = 1; id < nodeCount; id += 1) {
    const p = parent[id];
    if (p < 0) {
      continue;
    }
    const writeAt = writeOffsets[p];
    childIndex[writeAt] = id;
    writeOffsets[p] += 1;
  }

  return {
    kind: "json-fallback",
    rootPath: String(scan.root ?? "/"),
    totalSizeBytes: toNonNegative(scan.total_size_bytes ?? sizeBytes[ROOT_ID]),
    directories: toNonNegative(scan.directories),
    files: toNonNegative(scan.files),
    elapsedMs: toNonNegative(scan.elapsed_ms),
    errors: toNonNegative(scan.errors),
    ignored: toNonNegative(scan.ignored),
    skippedHidden: toNonNegative(scan.skipped_hidden),
    skippedSymlink: toNonNegative(scan.skipped_symlink),
    skippedOther: toNonNegative(scan.skipped_other),
    skippedTotal: toNonNegative(scan.skipped_total),
    errorSamples: Array.isArray(scan.error_samples) ? scan.error_samples : [],
    topIndex: new Uint32Array(0),

    nodeCount,
    parent,
    firstChild,
    childCount,
    childIndex,
    sizeBytes,
    fileCount,
    dirCount,

    nameOf(nodeId) {
      return names[nodeId];
    },

    parentOf(nodeId) {
      const value = parent[nodeId];
      return value < 0 ? null : value;
    },

    childrenOf(nodeId) {
      const start = firstChild[nodeId];
      const count = childCount[nodeId];
      const children = new Array(count);
      for (let i = 0; i < count; i += 1) {
        children[i] = childIndex[start + i];
      }
      children.sort((left, right) => sizeBytes[right] - sizeBytes[left]);
      return children;
    },

    sizeOf(nodeId) {
      return sizeBytes[nodeId] ?? 0;
    },

    fileCountOf(nodeId) {
      return fileCount[nodeId] ?? 0;
    },

    dirCountOf(nodeId) {
      return dirCount[nodeId] ?? 0;
    },

    childCountOf(nodeId) {
      return childCount[nodeId] ?? 0;
    },
  };
}

function renderTreemap() {
  const dataset = state.dataset;
  if (!dataset) {
    return;
  }

  const width = treemapElement.clientWidth;
  const height = treemapElement.clientHeight;
  if (width <= 4 || height <= 4) {
    return;
  }

  const children = dataset.childrenOf(state.currentNodeId);
  treemapElement.replaceChildren();

  if (children.length === 0) {
    showLoadError("Selected directory has no child directories.");
    return;
  }

  emptyState.style.display = "none";

  const rects = splitTreemap(children, 0, 0, width, height, dataset, []);
  rects.forEach((rect, index) => {
    if (rect.width < 2 || rect.height < 2) {
      return;
    }

    const cell = document.createElement("button");
    cell.type = "button";
    cell.className = "treemap-cell";
    cell.dataset.nodeId = String(rect.nodeId);
    cell.style.left = `${rect.x}px`;
    cell.style.top = `${rect.y}px`;
    cell.style.width = `${rect.width}px`;
    cell.style.height = `${rect.height}px`;
    cell.style.background = colorForNode(rect.nodeId);
    cell.style.animationDelay = `${Math.min(index * 6, 220)}ms`;

    const label = document.createElement("div");
    label.className = "cell-label";
    label.textContent = dataset.nameOf(rect.nodeId);
    cell.appendChild(label);

    const area = rect.width * rect.height;
    if (area > 2200) {
      const meta = document.createElement("div");
      meta.className = "cell-meta";
      meta.textContent = formatBytes(dataset.sizeOf(rect.nodeId));
      cell.appendChild(meta);
    }

    cell.addEventListener("mouseenter", () => {
      state.selectedNodeId = rect.nodeId;
      updateSelectedTreemapCell();
      renderSelectionMetrics();
    });

    cell.addEventListener("click", () => {
      state.selectedNodeId = rect.nodeId;
      updateSelectedTreemapCell();
      renderSelectionMetrics();

      if (dataset.childCountOf(rect.nodeId) > 0) {
        state.currentNodeId = rect.nodeId;
        renderTreemap();
        updateButtons();
      }
    });

    treemapElement.appendChild(cell);
    requestAnimationFrame(() => cell.classList.add("visible"));
  });

  updateSelectedTreemapCell();
}

function updateSelectedTreemapCell() {
  const selectedNode = String(state.selectedNodeId);
  const cells = treemapElement.querySelectorAll(".treemap-cell");
  cells.forEach((cell) => {
    cell.classList.toggle("selected", cell.dataset.nodeId === selectedNode);
  });
}

function splitTreemap(nodeIds, x, y, width, height, dataset, out) {
  if (nodeIds.length === 0) {
    return out;
  }

  if (nodeIds.length === 1) {
    out.push({ nodeId: nodeIds[0], x, y, width, height });
    return out;
  }

  const total = sumSizes(nodeIds, dataset);
  if (total <= 0) {
    const each = width / nodeIds.length;
    nodeIds.forEach((nodeId, index) => {
      out.push({ nodeId, x: x + each * index, y, width: each, height });
    });
    return out;
  }

  let bestIndex = 0;
  let running = 0;
  for (let i = 0; i < nodeIds.length; i += 1) {
    running += dataset.sizeOf(nodeIds[i]);
    bestIndex = i;
    if (running >= total / 2) {
      break;
    }
  }

  const leftNodes = nodeIds.slice(0, bestIndex + 1);
  const rightNodes = nodeIds.slice(bestIndex + 1);
  const leftSize = sumSizes(leftNodes, dataset);
  const ratio = clamp(leftSize / total, 0.05, 0.95);

  if (width >= height) {
    const leftWidth = Math.floor(width * ratio);
    splitTreemap(leftNodes, x, y, leftWidth, height, dataset, out);
    splitTreemap(rightNodes, x + leftWidth, y, width - leftWidth, height, dataset, out);
  } else {
    const topHeight = Math.floor(height * ratio);
    splitTreemap(leftNodes, x, y, width, topHeight, dataset, out);
    splitTreemap(rightNodes, x, y + topHeight, width, height - topHeight, dataset, out);
  }

  return out;
}

function sumSizes(nodeIds, dataset) {
  return nodeIds.reduce((total, nodeId) => total + Math.max(1, dataset.sizeOf(nodeId)), 0);
}

function renderScanMetrics() {
  const dataset = state.dataset;
  if (!dataset) {
    setMetrics(scanMetricsElement, [["status", "no data"]]);
    return;
  }

  setMetrics(scanMetricsElement, [
    ["format", dataset.kind],
    ["root", dataset.rootPath],
    ["size", formatBytes(dataset.totalSizeBytes)],
    ["dirs", formatNumber(dataset.directories)],
    ["files", formatNumber(dataset.files)],
    ["elapsed", `${formatNumber(dataset.elapsedMs)} ms`],
    ["ignored", formatNumber(dataset.ignored)],
    ["errors", formatNumber(dataset.errors)],
  ]);
}

function renderSelectionMetrics() {
  const dataset = state.dataset;
  if (!dataset) {
    setMetrics(selectionMetricsElement, [["status", "no selection"]]);
    return;
  }

  const nodeId = state.selectedNodeId;
  const total = Math.max(1, dataset.sizeOf(ROOT_ID));
  const size = dataset.sizeOf(nodeId);
  const pct = (size / total) * 100;

  setMetrics(selectionMetricsElement, [
    ["name", dataset.nameOf(nodeId)],
    ["path", fullPath(nodeId, dataset)],
    ["size", formatBytes(size)],
    ["share", `${pct.toFixed(2)}%`],
    ["files", formatNumber(dataset.fileCountOf(nodeId))],
    ["dirs", formatNumber(dataset.dirCountOf(nodeId))],
    ["children", formatNumber(dataset.childCountOf(nodeId))],
  ]);
}

function renderErrors() {
  const dataset = state.dataset;
  if (!dataset) {
    errorSummaryElement.textContent = "No data loaded.";
    errorListElement.replaceChildren();
    return;
  }

  errorSummaryElement.textContent = `${formatNumber(dataset.errors)} errors, ${formatNumber(
    dataset.errorSamples.length
  )} sampled`;
  errorListElement.replaceChildren();

  if (dataset.errorSamples.length === 0) {
    const li = document.createElement("li");
    li.textContent = "No error samples.";
    errorListElement.appendChild(li);
    return;
  }

  for (const sample of dataset.errorSamples.slice(0, 24)) {
    const li = document.createElement("li");
    li.textContent = `${sample.path ?? "unknown path"} (${sample.message ?? "error"})`;
    errorListElement.appendChild(li);
  }
}

function updateButtons() {
  const dataset = state.dataset;
  if (!dataset) {
    zoomOutButton.disabled = true;
    resetViewButton.disabled = true;
    return;
  }

  zoomOutButton.disabled = dataset.parentOf(state.currentNodeId) == null;
  resetViewButton.disabled = state.currentNodeId === ROOT_ID;
}

function fullPath(nodeId, dataset) {
  if (nodeId === ROOT_ID) {
    return dataset.rootPath;
  }

  const parts = [];
  let cursor = nodeId;
  while (cursor !== ROOT_ID && cursor != null) {
    parts.push(dataset.nameOf(cursor));
    cursor = dataset.parentOf(cursor);
  }
  parts.reverse();

  const rootPath = String(dataset.rootPath).replace(/[\\/]+$/, "");
  return `${rootPath}/${parts.join("/")}`;
}

function setMetrics(container, rows) {
  container.replaceChildren();
  for (const [label, value] of rows) {
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.textContent = String(value);
    container.append(dt, dd);
  }
}

function showLoadError(message) {
  emptyState.style.display = "grid";
  emptyState.innerHTML = `
    <h2>Unable to render scan</h2>
    <p class="mono">${escapeHtml(message)}</p>
  `;
}

function readU32(view, offset) {
  return view.getUint32(offset, true);
}

function readU64AsNumber(view, offset) {
  const raw = view.getBigUint64(offset, true);
  if (raw > BigInt(Number.MAX_SAFE_INTEGER)) {
    return Number.MAX_SAFE_INTEGER;
  }
  return Number(raw);
}

function decodeUtf8(bytes) {
  return new TextDecoder().decode(bytes);
}

function colorForNode(nodeId) {
  const hue = (nodeId * 37 + 91) % 360;
  return `hsl(${hue} 58% 58% / 0.86)`;
}

function formatBytes(bytes) {
  const value = toNonNegative(bytes);
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  if (value < 1024) {
    return `${value} B`;
  }

  let n = value;
  let idx = 0;
  while (n >= 1024 && idx < units.length - 1) {
    n /= 1024;
    idx += 1;
  }

  return `${n.toFixed(2)} ${units[idx]}`;
}

function formatNumber(value) {
  return toNonNegative(value).toLocaleString();
}

function toNonNegative(value) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function debounce(fn, waitMs) {
  let timeoutId = null;

  return (...args) => {
    if (timeoutId != null) {
      clearTimeout(timeoutId);
    }

    timeoutId = window.setTimeout(() => {
      timeoutId = null;
      fn(...args);
    }, waitMs);
  };
}

function escapeHtml(input) {
  return String(input)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
