local M = {}
-- symbolKindMap defines the mapping from ctags kinds to LSP symbol kinds
M.symbolKindMap = {
  ["alias"] = vim.lsp.protocol.SymbolKind.Variable,
  ["arg"] = vim.lsp.protocol.SymbolKind.Variable,
  ["attribute"] = vim.lsp.protocol.SymbolKind.Property,
  ["boolean"] = vim.lsp.protocol.SymbolKind.Constant,
  ["callback"] = vim.lsp.protocol.SymbolKind.Function,
  ["category"] = vim.lsp.protocol.SymbolKind.Enum,
  ["ccflag"] = vim.lsp.protocol.SymbolKind.Constant,
  ["cell"] = vim.lsp.protocol.SymbolKind.Variable,
  ["class"] = vim.lsp.protocol.SymbolKind.Class,
  ["collection"] = vim.lsp.protocol.SymbolKind.Class,
  ["command"] = vim.lsp.protocol.SymbolKind.Function,
  ["component"] = vim.lsp.protocol.SymbolKind.Struct,
  ["config"] = vim.lsp.protocol.SymbolKind.Constant,
  ["const"] = vim.lsp.protocol.SymbolKind.Constant,
  ["constant"] = vim.lsp.protocol.SymbolKind.Constant,
  ["constructor"] = vim.lsp.protocol.SymbolKind.Constructor,
  ["context"] = vim.lsp.protocol.SymbolKind.Variable,
  ["counter"] = vim.lsp.protocol.SymbolKind.Variable,
  ["data"] = vim.lsp.protocol.SymbolKind.Variable,
  ["dataset"] = vim.lsp.protocol.SymbolKind.Variable,
  ["def"] = vim.lsp.protocol.SymbolKind.Function,
  ["define"] = vim.lsp.protocol.SymbolKind.Constant,
  ["delegate"] = vim.lsp.protocol.SymbolKind.Class,
  ["enum"] = vim.lsp.protocol.SymbolKind.Enum,
  ["enumConstant"] = vim.lsp.protocol.SymbolKind.EnumMember,
  ["enumerator"] = vim.lsp.protocol.SymbolKind.Enum,
  ["environment"] = vim.lsp.protocol.SymbolKind.Variable,
  ["error"] = vim.lsp.protocol.SymbolKind.Enum,
  ["event"] = vim.lsp.protocol.SymbolKind.Event,
  ["exception"] = vim.lsp.protocol.SymbolKind.Class,
  ["externvar"] = vim.lsp.protocol.SymbolKind.Variable,
  ["face"] = vim.lsp.protocol.SymbolKind.Interface,
  ["feature"] = vim.lsp.protocol.SymbolKind.Property,
  ["field"] = vim.lsp.protocol.SymbolKind.Field,
  ["fn"] = vim.lsp.protocol.SymbolKind.Function,
  ["fun"] = vim.lsp.protocol.SymbolKind.Function,
  ["func"] = vim.lsp.protocol.SymbolKind.Function,
  ["function"] = vim.lsp.protocol.SymbolKind.Function,
  ["functionVar"] = vim.lsp.protocol.SymbolKind.Variable,
  ["functor"] = vim.lsp.protocol.SymbolKind.Class,
  ["generic"] = vim.lsp.protocol.SymbolKind.TypeParameter,
  ["getter"] = vim.lsp.protocol.SymbolKind.Method,
  ["global"] = vim.lsp.protocol.SymbolKind.Variable,
  ["globalVar"] = vim.lsp.protocol.SymbolKind.Variable,
  ["group"] = vim.lsp.protocol.SymbolKind.Enum,
  ["guard"] = vim.lsp.protocol.SymbolKind.Variable,
  ["handler"] = vim.lsp.protocol.SymbolKind.Function,
  ["icon"] = vim.lsp.protocol.SymbolKind.Enum,
  ["id"] = vim.lsp.protocol.SymbolKind.Variable,
  ["implementation"] = vim.lsp.protocol.SymbolKind.Class,
  ["index"] = vim.lsp.protocol.SymbolKind.Variable,
  ["infoitem"] = vim.lsp.protocol.SymbolKind.Variable,
  ["instance"] = vim.lsp.protocol.SymbolKind.Variable,
  ["interface"] = vim.lsp.protocol.SymbolKind.Interface,
  ["it"] = vim.lsp.protocol.SymbolKind.Variable,
  ["jurisdiction"] = vim.lsp.protocol.SymbolKind.Variable,
  ["library"] = vim.lsp.protocol.SymbolKind.Module,
  ["list"] = vim.lsp.protocol.SymbolKind.Variable,
  ["local"] = vim.lsp.protocol.SymbolKind.Variable,
  ["localVariable"] = vim.lsp.protocol.SymbolKind.Variable,
  ["locale"] = vim.lsp.protocol.SymbolKind.Variable,
  ["localvar"] = vim.lsp.protocol.SymbolKind.Variable,
  ["macro"] = vim.lsp.protocol.SymbolKind.Variable,
  ["macroParameter"] = vim.lsp.protocol.SymbolKind.Variable,
  ["macrofile"] = vim.lsp.protocol.SymbolKind.File,
  ["macroparam"] = vim.lsp.protocol.SymbolKind.Variable,
  ["makefile"] = vim.lsp.protocol.SymbolKind.File,
  ["map"] = vim.lsp.protocol.SymbolKind.Variable,
  ["method"] = vim.lsp.protocol.SymbolKind.Method,
  ["methodSpec"] = vim.lsp.protocol.SymbolKind.Method,
  ["misc"] = vim.lsp.protocol.SymbolKind.Variable,
  ["module"] = vim.lsp.protocol.SymbolKind.Module,
  ["name"] = vim.lsp.protocol.SymbolKind.Variable,
  ["namespace"] = vim.lsp.protocol.SymbolKind.Module,
  ["nettype"] = vim.lsp.protocol.SymbolKind.TypeParameter,
  ["newFile"] = vim.lsp.protocol.SymbolKind.File,
  ["node"] = vim.lsp.protocol.SymbolKind.Variable,
  ["object"] = vim.lsp.protocol.SymbolKind.Class,
  ["oneof"] = vim.lsp.protocol.SymbolKind.Enum,
  ["operator"] = vim.lsp.protocol.SymbolKind.Operator,
  ["output"] = vim.lsp.protocol.SymbolKind.Variable,
  ["package"] = vim.lsp.protocol.SymbolKind.Module,
  ["param"] = vim.lsp.protocol.SymbolKind.Variable,
  ["parameter"] = vim.lsp.protocol.SymbolKind.Variable,
  ["paramEntity"] = vim.lsp.protocol.SymbolKind.Variable,
  ["part"] = vim.lsp.protocol.SymbolKind.Variable,
  ["placeholder"] = vim.lsp.protocol.SymbolKind.Variable,
  ["port"] = vim.lsp.protocol.SymbolKind.Variable,
  ["process"] = vim.lsp.protocol.SymbolKind.Function,
  ["property"] = vim.lsp.protocol.SymbolKind.Property,
  ["prototype"] = vim.lsp.protocol.SymbolKind.Variable,
  ["protocol"] = vim.lsp.protocol.SymbolKind.Class,
  ["provider"] = vim.lsp.protocol.SymbolKind.Class,
  ["publication"] = vim.lsp.protocol.SymbolKind.Variable,
  ["qkey"] = vim.lsp.protocol.SymbolKind.Variable,
  ["receiver"] = vim.lsp.protocol.SymbolKind.Variable,
  ["record"] = vim.lsp.protocol.SymbolKind.Struct,
  ["region"] = vim.lsp.protocol.SymbolKind.Variable,
  ["register"] = vim.lsp.protocol.SymbolKind.Variable,
  ["repoid"] = vim.lsp.protocol.SymbolKind.Variable,
  ["report"] = vim.lsp.protocol.SymbolKind.Variable,
  ["repositoryId"] = vim.lsp.protocol.SymbolKind.Variable,
  ["repr"] = vim.lsp.protocol.SymbolKind.Variable,
  ["resource"] = vim.lsp.protocol.SymbolKind.Variable,
  ["response"] = vim.lsp.protocol.SymbolKind.Function,
  ["role"] = vim.lsp.protocol.SymbolKind.Class,
  ["rpc"] = vim.lsp.protocol.SymbolKind.Variable,
  ["schema"] = vim.lsp.protocol.SymbolKind.Variable,
  ["script"] = vim.lsp.protocol.SymbolKind.File,
  ["sequence"] = vim.lsp.protocol.SymbolKind.Variable,
  ["server"] = vim.lsp.protocol.SymbolKind.Class,
  ["service"] = vim.lsp.protocol.SymbolKind.Class,
  ["setter"] = vim.lsp.protocol.SymbolKind.Method,
  ["signal"] = vim.lsp.protocol.SymbolKind.Function,
  ["singletonMethod"] = vim.lsp.protocol.SymbolKind.Method,
  ["slot"] = vim.lsp.protocol.SymbolKind.Variable,
  ["software"] = vim.lsp.protocol.SymbolKind.Class,
  ["sourcefile"] = vim.lsp.protocol.SymbolKind.File,
  ["standard"] = vim.lsp.protocol.SymbolKind.Variable,
  ["string"] = vim.lsp.protocol.SymbolKind.String,
  ["structure"] = vim.lsp.protocol.SymbolKind.Struct,
  ["stylesheet"] = vim.lsp.protocol.SymbolKind.Variable,
  ["submethod"] = vim.lsp.protocol.SymbolKind.Method,
  ["submodule"] = vim.lsp.protocol.SymbolKind.Module,
  ["subprogram"] = vim.lsp.protocol.SymbolKind.Function,
  ["subprogspec"] = vim.lsp.protocol.SymbolKind.Variable,
  ["subroutine"] = vim.lsp.protocol.SymbolKind.Function,
  ["subsection"] = vim.lsp.protocol.SymbolKind.Variable,
  ["subst"] = vim.lsp.protocol.SymbolKind.Variable,
  ["substdef"] = vim.lsp.protocol.SymbolKind.Variable,
  ["tag"] = vim.lsp.protocol.SymbolKind.Variable,
  ["template"] = vim.lsp.protocol.SymbolKind.Variable,
  ["test"] = vim.lsp.protocol.SymbolKind.Variable,
  ["theme"] = vim.lsp.protocol.SymbolKind.Variable,
  ["theorem"] = vim.lsp.protocol.SymbolKind.Variable,
  ["thriftFile"] = vim.lsp.protocol.SymbolKind.File,
  ["throwsparam"] = vim.lsp.protocol.SymbolKind.Variable,
  ["title"] = vim.lsp.protocol.SymbolKind.Variable,
  ["token"] = vim.lsp.protocol.SymbolKind.Variable,
  ["toplevelVariable"] = vim.lsp.protocol.SymbolKind.Variable,
  ["trait"] = vim.lsp.protocol.SymbolKind.Variable,
  ["type"] = vim.lsp.protocol.SymbolKind.Struct,
  ["typealias"] = vim.lsp.protocol.SymbolKind.Variable,
  ["typedef"] = vim.lsp.protocol.SymbolKind.TypeParameter,
  ["typespec"] = vim.lsp.protocol.SymbolKind.TypeParameter,
  ["union"] = vim.lsp.protocol.SymbolKind.Struct,
  ["username"] = vim.lsp.protocol.SymbolKind.Variable,
  ["val"] = vim.lsp.protocol.SymbolKind.Variable,
  ["value"] = vim.lsp.protocol.SymbolKind.Variable,
  ["var"] = vim.lsp.protocol.SymbolKind.Variable,
  ["variable"] = vim.lsp.protocol.SymbolKind.Variable,
  ["vector"] = vim.lsp.protocol.SymbolKind.Variable,
  ["version"] = vim.lsp.protocol.SymbolKind.Variable,
  ["video"] = vim.lsp.protocol.SymbolKind.File,
  ["view"] = vim.lsp.protocol.SymbolKind.Variable,
  ["wrapper"] = vim.lsp.protocol.SymbolKind.Variable,
  ["xdata"] = vim.lsp.protocol.SymbolKind.Variable,
  ["xinput"] = vim.lsp.protocol.SymbolKind.Variable,
  ["xtask"] = vim.lsp.protocol.SymbolKind.Variable,
}

return M
