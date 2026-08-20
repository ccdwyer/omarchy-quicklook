//! Sample Rust for QuickLook syntax highlighting.
use std::collections::BTreeMap;

/// Render a themed invoice line.
pub fn invoice_total(lines: &[f64]) -> f64 {
    lines.iter().copied().sum()
}

fn main() {
    let mut items = BTreeMap::new();
    items.insert("widget-pro", 1000.00);
    items.insert("support", 240.00);
    // comments stay dim against the Omarchy palette
    let total: f64 = items.values().copied().sum();
    println!("INVOICE #1042 total ${:.2}", total);
    if total > 1000.0 {
        println!("priority account");
    }
}
