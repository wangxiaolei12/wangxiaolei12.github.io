# Xiaolei Wang's Personal Blog

This is my personal blog built with Jekyll and hosted on GitHub Pages, focusing on Linux kernel development, graphics programming, and embedded systems.

## About

I'm Xiaolei Wang, a Linux kernel developer working on the media subsystem. This blog documents my journey in kernel development, technical insights, and contributions to open source projects.

## Features

- Clean, minimalist design inspired by modern web standards
- Responsive layout for all devices
- Syntax highlighting for code snippets
- Fast loading times with static site generation
- SEO optimized

## Local Development

### Prerequisites

- Ruby 2.7 or higher
- Jekyll 4.3+
- Bundler

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/wangxiaolei12/wangxiaolei12.github.io.git
   cd wangxiaolei12.github.io
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Run locally:
   ```bash
   bundle exec jekyll serve
   ```

4. Visit `http://localhost:4000`

## Writing Posts

Create new posts in `_src/_posts/` with the format:
```
YYYY-MM-DD-title.md
```

Each post should start with front matter:
```yaml
---
title: "Post Title"
date: YYYY-MM-DD HH:MM:SS +TIMEZONE
excerpt: "Brief description"
---
```

## Project Structure

```
├── _config.yml              # Jekyll configuration
├── Gemfile                  # Ruby dependencies
├── _src/                    # Source files
│   ├── _layouts/           # Page layouts
│   ├── _includes/          # Reusable components
│   ├── _posts/             # Blog posts
│   ├── assets/             # CSS, JS, images
│   ├── index.md            # Homepage
│   └── about-me.md         # About page
└── README.md               # This file
```

## Customization

- Edit `_config.yml` for site settings
- Modify `_src/assets/style.css` for styling
- Update layouts in `_src/_layouts/`
- Add new pages in `_src/` directory

## Deployment

This blog is automatically deployed to GitHub Pages when changes are pushed to the main branch.

## License

This project is open source and available under the [MIT License](LICENSE).

## Contact

- Email: xiaolei.wang@windriver.com
- GitHub: [@wangxiaolei12](https://github.com/wangxiaolei12)
- Blog: [https://wangxiaolei12.github.io](https://wangxiaolei12.github.io)
