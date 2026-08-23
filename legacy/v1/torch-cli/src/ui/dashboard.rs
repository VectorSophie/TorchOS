use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Terminal,
};
use std::io;
use sysinfo::System;

pub fn run_top() -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut sys = System::new_all();

    loop {
        terminal.draw(|f| {
            sys.refresh_all();

            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Length(3), Constraint::Min(10)].as_ref())
                .split(f.size());

            let cpu_usage = sys.global_cpu_info().cpu_usage();
            let mem_used = sys.used_memory() / 1024 / 1024;
            let mem_total = sys.total_memory() / 1024 / 1024;

            let header = Paragraph::new(format!(
                " CPU: {:.1}% | MEM: {}MB / {}MB | Torch OS: Active",
                cpu_usage, mem_used, mem_total
            ))
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(" Torch-Top (v0.1) "),
            );
            f.render_widget(header, chunks[0]);

            let labs = [
                ListItem::new(" - lab-1: Running [PID: 4521] - GPU: 45% VRAM"),
                ListItem::new(" - lab-2: Suspended"),
                ListItem::new(" - base-lab: IDLE"),
            ];
            let lab_list = List::new(labs).block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(" Research Labs Health "),
            );
            f.render_widget(lab_list, chunks[1]);
        })?;

        if event::poll(std::time::Duration::from_millis(500))? {
            if let Event::Key(key) = event::read()? {
                if let KeyCode::Char('q') = key.code {
                    break;
                }
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    Ok(())
}
