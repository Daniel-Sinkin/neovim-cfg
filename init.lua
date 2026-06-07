-- Entry point. The real config lives under lua/config/ (non-plugin setup)
-- and lua/custom/plugins/ (one file per plugin spec). See private/AGENTS.md
-- for the layout map.

require 'config.options'
require 'config.keymaps'
require 'config.autocmds'
require 'config.lazy'
require 'config.snippets'

require('custom.julia_scope').setup()
require('custom.julia_progress').setup()
require('custom.dans_frontend_cpp').setup()
require('custom.cpp_type_snippets').setup()
require('custom.cpp_doc_markdown').setup()
require('custom.dans_perf').setup()
require('custom.dans_macros').setup()
