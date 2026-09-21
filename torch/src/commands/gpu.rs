use super::diagnose::parse_lspci_mm;
use super::doctor::out;

pub fn run() -> anyhow::Result<u8> {
    let Some(text) = out("lspci", &["-mm"]) else {
        eprintln!("lspci not available (install pciutils)");
        return Ok(3);
    };
    let gpus = parse_lspci_mm(&text);
    if gpus.is_empty() {
        println!("No GPU detected.");
        return Ok(0);
    }
    for g in gpus {
        println!("{} {}  [{}]", g["vendor"].as_str().unwrap_or("?"), g["device"].as_str().unwrap_or("?"), g["slot"].as_str().unwrap_or("?"));
    }
    Ok(0)
}
