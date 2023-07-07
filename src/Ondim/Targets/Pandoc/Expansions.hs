module Ondim.Targets.Pandoc.Expansions where

import Data.Text qualified as T
import Ondim
import Ondim.Extra.Standard (attrSub, bindText, standardMap)
import Ondim.Targets.Pandoc.Instances ()
import Text.Pandoc.Definition
import Text.Pandoc.Walk

bindDefaults ::
  forall m t.
  Monad m =>
  Ondim m t ->
  Ondim m t
bindDefaults st =
  st
    `binding` do
      standardMap
      "bind-text" ## bindText (stringify @Block)
      "bind-text" ## bindText (stringify @Inline)
    `bindingFilters` do
      "attrSub" $* attrSub '!' ('(', ')')

-- Miscellaneous (from Text.Pandoc.Shared)

stringify :: Walkable Inline a => a -> T.Text
stringify = query go
  where
    go :: Inline -> T.Text
    go Space = " "
    go SoftBreak = " "
    go (Str x) = x
    go (Code _ x) = x
    go (Math _ x) = x
    go LineBreak = " "
    go _ = ""
