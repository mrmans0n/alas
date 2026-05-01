use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkdownBlock {
    Heading {
        level: u8,
        text: String,
    },
    Paragraph(String),
    CodeBlock {
        language: Option<String>,
        code: String,
    },
    ListItem(String),
    BlockQuote(String),
    Rule,
}

pub fn parse_markdown_blocks(markdown: &str) -> Vec<MarkdownBlock> {
    let parser = Parser::new_ext(markdown, Options::empty());
    let mut blocks = Vec::new();
    let mut stack = Vec::<OpenBlock>::new();

    for event in parser {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                stack.push(OpenBlock::Heading {
                    level: heading_level_number(level),
                    text: String::new(),
                });
            }
            Event::Start(Tag::Paragraph) => stack.push(OpenBlock::Paragraph(String::new())),
            Event::Start(Tag::CodeBlock(kind)) => {
                let language = match kind {
                    CodeBlockKind::Fenced(language) if !language.is_empty() => {
                        Some(language.to_string())
                    }
                    CodeBlockKind::Fenced(_) | CodeBlockKind::Indented => None,
                };
                stack.push(OpenBlock::CodeBlock {
                    language,
                    code: String::new(),
                });
            }
            Event::Start(Tag::Item) => stack.push(OpenBlock::ListItem(String::new())),
            Event::Start(Tag::BlockQuote(_)) => stack.push(OpenBlock::BlockQuote(String::new())),
            Event::End(TagEnd::Heading(_)) => {
                if let Some(OpenBlock::Heading { level, text }) = stack.pop() {
                    blocks.push(MarkdownBlock::Heading {
                        level,
                        text: text.trim().to_string(),
                    });
                }
            }
            Event::End(TagEnd::Paragraph) => {
                if let Some(OpenBlock::Paragraph(text)) = stack.pop()
                    && !append_text_to_parent(stack.last_mut(), text.trim())
                {
                    push_text_block(
                        &mut blocks,
                        MarkdownBlock::Paragraph(text.trim().to_string()),
                    );
                }
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some(OpenBlock::CodeBlock { language, code }) = stack.pop() {
                    blocks.push(MarkdownBlock::CodeBlock { language, code });
                }
            }
            Event::End(TagEnd::Item) => {
                if let Some(OpenBlock::ListItem(text)) = stack.pop()
                    && !append_text_to_parent(stack.last_mut(), text.trim())
                {
                    push_text_block(
                        &mut blocks,
                        MarkdownBlock::ListItem(text.trim().to_string()),
                    );
                }
            }
            Event::End(TagEnd::BlockQuote(_)) => {
                if let Some(OpenBlock::BlockQuote(text)) = stack.pop() {
                    push_text_block(
                        &mut blocks,
                        MarkdownBlock::BlockQuote(text.trim().to_string()),
                    );
                }
            }
            Event::Rule => blocks.push(MarkdownBlock::Rule),
            Event::Text(text) | Event::Code(text) => append_text(&mut stack, &text),
            Event::SoftBreak | Event::HardBreak => append_text(&mut stack, "\n"),
            Event::Html(html) | Event::InlineHtml(html) => append_text(&mut stack, &html),
            Event::TaskListMarker(checked) => {
                append_text(&mut stack, if checked { "[x] " } else { "[ ] " });
            }
            Event::Start(_) | Event::End(_) | Event::FootnoteReference(_) => {}
            #[allow(unreachable_patterns)]
            _ => {}
        }
    }

    blocks
}

fn push_text_block(blocks: &mut Vec<MarkdownBlock>, block: MarkdownBlock) {
    let is_empty = match &block {
        MarkdownBlock::Heading { text, .. }
        | MarkdownBlock::Paragraph(text)
        | MarkdownBlock::ListItem(text)
        | MarkdownBlock::BlockQuote(text) => text.is_empty(),
        MarkdownBlock::CodeBlock { .. } | MarkdownBlock::Rule => false,
    };
    if !is_empty {
        blocks.push(block);
    }
}

fn append_text(stack: &mut [OpenBlock], text: &str) {
    let Some(block) = stack.last_mut() else {
        return;
    };
    match block {
        OpenBlock::Heading { text: target, .. }
        | OpenBlock::Paragraph(target)
        | OpenBlock::ListItem(target)
        | OpenBlock::BlockQuote(target) => target.push_str(text),
        OpenBlock::CodeBlock { code, .. } => code.push_str(text),
    }
}

fn append_text_to_parent(parent: Option<&mut OpenBlock>, text: &str) -> bool {
    let Some(parent) = parent else {
        return false;
    };
    match parent {
        OpenBlock::ListItem(target) | OpenBlock::BlockQuote(target) => {
            if !target.is_empty() && !text.is_empty() {
                target.push('\n');
            }
            target.push_str(text);
            true
        }
        OpenBlock::Heading { .. } | OpenBlock::Paragraph(_) | OpenBlock::CodeBlock { .. } => false,
    }
}

fn heading_level_number(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

enum OpenBlock {
    Heading {
        level: u8,
        text: String,
    },
    Paragraph(String),
    CodeBlock {
        language: Option<String>,
        code: String,
    },
    ListItem(String),
    BlockQuote(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_core_markdown_blocks() {
        let blocks = parse_markdown_blocks(
            "# Title\n\nParagraph with `code`.\n\n- one\n- two\n\n> quoted\n\n```rust\nfn main() {}\n```\n\n---\n",
        );

        assert_eq!(
            blocks,
            vec![
                MarkdownBlock::Heading {
                    level: 1,
                    text: "Title".to_string()
                },
                MarkdownBlock::Paragraph("Paragraph with code.".to_string()),
                MarkdownBlock::ListItem("one".to_string()),
                MarkdownBlock::ListItem("two".to_string()),
                MarkdownBlock::BlockQuote("quoted".to_string()),
                MarkdownBlock::CodeBlock {
                    language: Some("rust".to_string()),
                    code: "fn main() {}\n".to_string()
                },
                MarkdownBlock::Rule,
            ]
        );
    }

    #[test]
    fn preserves_container_context_for_nested_paragraphs() {
        let blocks = parse_markdown_blocks("- list item\n\n> quoted paragraph\n");

        assert_eq!(
            blocks,
            vec![
                MarkdownBlock::ListItem("list item".to_string()),
                MarkdownBlock::BlockQuote("quoted paragraph".to_string()),
            ]
        );
    }

    #[test]
    fn preserves_blockquote_context_for_nested_list_items() {
        let blocks = parse_markdown_blocks("> - quoted item\n");

        assert_eq!(
            blocks,
            vec![MarkdownBlock::BlockQuote("quoted item".to_string())]
        );
    }
}
