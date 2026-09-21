// Rune Weaver Dashboard — React DOM entrypoint.

import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";
import { setupLabelSelectionFix } from "./labelSelectionFix";

// Single global capture-phase document listener for the app lifetime; retained
// for HMR dispose so module reloads never double-attach the handler.
const cleanupLabelSelectionFix = setupLabelSelectionFix();
if (import.meta.hot) {
  import.meta.hot.dispose(cleanupLabelSelectionFix);
}

const root = document.getElementById("root");
if (!root) {
  throw new Error("Missing #root element");
}

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
