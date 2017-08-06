{-# LANGUAGE DataKinds, GADTs, InstanceSigs, MultiParamTypeClasses, NoStrictData, RankNTypes, ScopedTypeVariables, StandaloneDeriving, TypeFamilies, TypeOperators #-}
-- | Assignment of AST onto some other structure (typically terms).
--
--   Parsing yields an AST represented as a Rose tree labelled with symbols in the language’s grammar and source locations (byte Range and Span). An Assignment represents a (partial) map from AST nodes onto some other structure; in essence, it’s a parser that operates over trees. (For our purposes, this structure is typically Terms annotated with source locations.) Assignments are able to match based on symbol, sequence, and hierarchy; thus, in @x = y@, both @x@ and @y@ might have the same symbol, @Identifier@, the left can be assigned to a variable declaration, while the right can be assigned to a variable reference.
--
--   Assignments can be any of the following primitive rules:
--
--   1. 'symbol' rules match a node against a specific symbol in the source language’s grammar; they succeed iff a) there is a current node, and b) its symbol is equal to the argument symbol. Matching a 'symbol' rule does not advance past the current node, meaning that you can match a node against a symbol and also e.g. match against the node’s 'children'. This also means that some care must be taken, as repeating a symbol with 'many' or 'some' (see below) will never advance past the current node and could therefore loop forever.
--
--   2. 'location' rules always succeed, and produce the current node’s Location (byte Range and Span). If there is no current node (i.e. if matching has advanced past the root node or past the last child node when operating within a 'children' rule), the location is instead the end of the most recently matched node, specified as a zero-width Range and Span. 'location' rules do not advance past the current node, meaning that you can both match a node’s 'location' and other properties.
--
--   3. 'source' rules succeed whenever there is a current node (i.e. matching has not advanced past the root node or the last child node when operating within a 'children' rule), and produce its source as a ByteString. 'source' is intended to match leaf nodes such as e.g. comments. 'source' rules advance past the current node.
--
--   4. 'children' rules apply their argument (an assignment) to the children of the current node, succeeding iff a) there is a current node, b) the argument assignment matches the children, and c) there are no (regular) nodes left over (see below re: tokens), producing the result of matching the argument assignment against the children. 'children' rules can match a node with no child nodes if their argument can successfully match at the end of input.
--
--   5. Via the 'Alternative' instance, 'empty' assignments always fail. This can be used (in combination with the 'Monad' instance) to (for example) fail if a 'source' assignment produces an ill-formatted ByteString. However, see below re: committed choice.
--
--   6. Via the 'Applicative' instance, 'pure' (or via the 'Monad' instance, 'return') assignments always succeed, producing the passed value. They do not advance past the current node. In combination with the 'Alternative' instance, 'pure' can provide default values when optional syntax is not present in the AST.
--
--   Assignments can further be combined in a few different ways:
--
--   1. The 'Functor' instance maps values from the AST (Location, ByteString, etc.) into another structure.
--
--   2. The 'Applicative' instance assigns sequences of (sibling) AST nodes in order, as well as providing 'pure' assignments (see above). Most assignments of a single piece of syntax consist of an 'Applicative' chain of assignments.
--
--   3. The 'Alternative' instance chooses between a set of assignments, as well as providing 'empty' assignments (see above). See below re: committed choice for best practices for efficiency & error reporting when it comes to assigning multiple alternatives. Most high-level assignments (e.g. “declaration” or “statement” assignments) consist of choices among two or more 'Applicative' chains of assignments, mirroring the structure of the parser’s choices. The 'Alternative' instance also enables repetitions via the 'many' (≥ 0 repetitions) and 'some' (≥ 1 repetition) methods. Finally, the 'optional' function uses the 'Alternative' instance to assign a value in 'Maybe', succeeding with 'Nothing' when unmatched.
--
--   4. The 'Monad' instance allows assignments to depend on the results of earlier assignments. In general, most assignments should not be written using the 'Monad' instance; however, some specific situations require it, e.g. assigning 'x += y' to be equivalent to 'x = x + y'.
--
--
--   == Best practices
--
--   Because of their flexibility, the same assignment can often be written in multiple different ways. The following best practices should ensure efficient assignment with clear error messages for ill-formed AST.
--
--   === Committed choice
--
--   Assignments can represent alternatives as either committed or uncommitted choices, both written with '<|>'. “Committed” in this context means that a failure in one of the alternatives will not result in backtracking followed by an attempt of one of the other alternatives; thus, committed choice is more efficient. (By the same token, it enables much better error messages since backtracking erases most of the relevant context.) Committed choices are constructed via the following rules:
--
--   1. 'empty' is dropped from choices:
--   prop> empty <|> a = a -- empty is the left-identity of <|>
--   prop> a <|> empty = a -- empty is the right-identity of <|>
--
--   2. 'symbol' rules construct a committed choice (with only a single alternative).
--
--   3. 'fmap' (and by extension '<$>' and '<$') of a committed choice is a committed choice.
--
--   4. '<*>' (and by extension '*>' and '<*') with a committed choice on the left is a committed choice.
--
--   5. '>>=' (and by extension '>>', '=<<', and '<<') of a committed choice is a committed choice. It may be helpful to think of this and the above rule for '<*>' as “sequences starting with committed choices remain committed choices.”
--
--   6. '<|>' of two committed choices is a committed choice.
--
--   Finally, if a given choice is not a committed choice, it is an uncommitted choice.
--
--   Distilling the above, the rule of thumb is to always start an assignment for a given piece of syntax with either a 'symbol' rule or an 'fmap' over a 'symbol' rule. When assigning multiple pieces of syntax, place any known uncommitted choices at the (rightmost) end of the chain; '<|>' is left-associative, so this guarantees that you’re adding at most one uncommitted choice on top of the ones already present.
--
--   === Matching tokens
--
--   AST symbols are classified by their 'symbolType' as either 'Regular', 'Anonymous', or 'Auxiliary'. 'Auxiliary' never appears in ASTs; 'Regular' is for the symbols of explicitly named productions in the grammar, and 'Anonymous' is for unnamed productions of content such as tokens. Most of the time, assignments are only concerned with the named productions, and thus will be using 'Regular' symbols. Therefore, when matching a committed choice of all-'Regular' symbols, nodes with 'Anonymous' symbols will be skipped. However, in some cases grammars don’t provide a named symbol for e.g. every kind of infix operator, and thus the only way to differentiate between them is by means of a 'symbol' rule for an 'Anonymous' token. In these cases, and before every other kind of assignment, the 'Anonymous' nodes will not be skipped so that matching can succeed.
--
--   Therefore, in addition to the rule of thumb for committed choices (see above), try to match 'Regular' symbols up front, and only match 'Anonymous' ones in the middle of a chain. That will ensure that you don’t have to make redundant effort to explicitly skip 'Anonymous' nodes ahead of multiple alternatives, and can instead rely on them being automatically skipped except when explicitly required.
module Data.Syntax.Assignment
-- Types
( Assignment
, Location
, AST
, Node(..)
, nodeLocation
-- Combinators
, Alternative(..)
, MonadError(..)
, location
, project
, symbol
, source
, children
, while
, until
-- Results
, Error(..)
, nodeError
, errorCallStack
, formatError
, firstSet
-- Running
, assignBy
, runAssignment
-- Implementation details (for testing)
, State(..)
, makeState
, module Parsers
) where

import Control.Arrow ((&&&))
import Control.Applicative
import Control.Comonad.Cofree
import Control.Monad ((<=<), guard)
import Control.Monad.Error.Class hiding (Error)
import Control.Monad.Free.Freer
import Data.Array
import Data.Bifunctor
import Data.Blob
import Data.ByteString (isSuffixOf)
import Data.ByteString.Char8 (ByteString, pack, unpack)
import Data.Error
import Data.Foldable
import Data.Function
import Data.Functor.Classes
import qualified Data.Functor.Foldable as F hiding (Nil)
import Data.Ix (inRange)
import Data.List (union)
import Data.List.NonEmpty ((<|), NonEmpty(..), nonEmpty)
import Data.Maybe
import Data.Record
import Data.Semigroup
import qualified Data.Source as Source (Source, fromBytes, slice, sourceBytes, sourceLines)
import GHC.Stack
import qualified Info
import Prelude hiding (head, until)
import System.Console.ANSI
import Text.Parser.Combinators as Parsers
import Text.Parser.TreeSitter.Language

-- | Assignment from an AST with some set of 'symbol's onto some other value.
--
--   This is essentially a parser.
type Assignment ast grammar = Freer (AssignmentF ast grammar)

data AssignmentF ast grammar a where
  End :: HasCallStack => AssignmentF ast grammar ()
  Location :: HasCallStack => AssignmentF ast grammar (Record Location)
  Project :: HasCallStack => (forall x. F.Base ast x -> a) -> AssignmentF ast grammar a
  Source :: HasCallStack => AssignmentF ast grammar ByteString
  Children :: HasCallStack => Assignment ast grammar a -> AssignmentF ast grammar a
  Choose :: HasCallStack => [grammar] -> Array grammar (Maybe a) -> AssignmentF ast grammar a
  Many :: HasCallStack => Assignment ast grammar a -> AssignmentF ast grammar [a]
  Alt :: HasCallStack => NonEmpty a -> AssignmentF ast grammar a
  Throw :: HasCallStack => Maybe (Error grammar) -> AssignmentF ast grammar a
  Catch :: HasCallStack => Assignment ast grammar a -> (Error grammar -> Assignment ast grammar a) -> AssignmentF ast grammar a
  Label :: HasCallStack => Assignment ast grammar a -> String -> AssignmentF ast grammar a

-- | Zero-width production of the current location.
--
--   If assigning at the end of input or at the end of a list of children, the loccation will be returned as an empty Range and Span at the current offset. Otherwise, it will be the Range and Span of the current node.
location :: HasCallStack => Assignment ast grammar (Record Location)
location = withFrozenCallStack $ Location `Then` return

-- | Zero-width projection of the current node.
--
--   Since this is zero-width, care must be taken not to repeat it without chaining on other rules. I.e. @many (project f *> b)@ is fine, but @many (project f)@ is not.
project :: HasCallStack => (forall x. F.Base ast x -> a) -> Assignment ast grammar a
project projection = withFrozenCallStack $ Project projection `Then` return

-- | Zero-width match of a node with the given symbol, producing the current node’s location.
--
--   Since this is zero-width, care must be taken not to repeat it without chaining on other rules. I.e. @many (symbol A *> b)@ is fine, but @many (symbol A)@ is not.
symbol :: (Ix grammar, HasCallStack) => grammar -> Assignment ast grammar (Record Location)
symbol s = withFrozenCallStack $ Choose [s] (array (s, s) [(s, Just location)]) `Then` id

-- | A rule to produce a node’s source as a ByteString.
source :: HasCallStack => Assignment ast grammar ByteString
source = withFrozenCallStack $ Source `Then` return

-- | Match a node by applying an assignment to its children.
children :: HasCallStack => Assignment ast grammar a -> Assignment ast grammar a
children forEach = withFrozenCallStack $ Children forEach `Then` return


-- | Collect a list of values passing a predicate.
while :: (Alternative m, Monad m, HasCallStack) => (a -> Bool) -> m a -> m [a]
while predicate step = many $ do
  result <- step
  guard (predicate result)
  pure result

-- | Collect a list of values failing a predicate.
until :: (Alternative m, Monad m, HasCallStack) => (a -> Bool) -> m a -> m [a]
until = while . (not .)


-- | A location specified as possibly-empty intervals of bytes and line/column positions.
type Location = '[Info.Range, Info.Span]

-- | An AST node labelled with symbols and source location.
type AST grammar = Cofree [] (Node grammar)

data Node grammar = Node
  { nodeSymbol :: !grammar
  , nodeByteRange :: {-# UNPACK #-} !Info.Range
  , nodeSpan :: {-# UNPACK #-} !Info.Span
  }
  deriving (Eq, Show)

nodeLocation :: Node grammar -> Record Location
nodeLocation Node{..} = nodeByteRange :. nodeSpan :. Nil

nodeError :: HasCallStack => [grammar] -> Node grammar -> Error grammar
nodeError expected (Node actual _ span) = Error span expected (Just actual)


type IncludeSource = Bool
type Colourize = Bool

-- | Format an 'Error', optionally with reference to the source where it occurred.
formatError :: IncludeSource -> Colourize -> Blob -> Info.Span -> [String] -> Maybe String -> String
formatError includeSource colourize Blob{..} errorSpan errorExpected errorActual
  = ($ "")
  $ withSGRCode colourize [SetConsoleIntensity BoldIntensity] (showSpan (maybe Nothing (const (Just blobPath)) blobKind) errorSpan . showString ": ")
  . withSGRCode colourize [SetColor Foreground Vivid Red] (showString "error" . showString ": " . showExpectation errorExpected errorActual . showChar '\n')
  . (if includeSource
    then showString (unpack context) . (if "\n" `isSuffixOf` context then id else showChar '\n')
       . showString (replicate (succ (Info.posColumn (Info.spanStart errorSpan) + lineNumberDigits)) ' ') . withSGRCode colourize [SetColor Foreground Vivid Green] (showChar '^' . showChar '\n')
    else id)
  . showString (prettyCallStack callStack) . showChar '\n'
  where context = maybe "\n" (Source.sourceBytes . sconcat) (nonEmpty [ Source.fromBytes (pack (showLineNumber i)) <> Source.fromBytes ": " <> l | (i, l) <- zip [1..] (Source.sourceLines blobSource), inRange (Info.posLine (Info.spanStart errorSpan) - 2, Info.posLine (Info.spanStart errorSpan)) i ])
        showLineNumber n = let s = show n in replicate (lineNumberDigits - length s) ' ' <> s
        lineNumberDigits = succ (floor (logBase 10 (fromIntegral (Info.posLine (Info.spanStart errorSpan)) :: Double)))

withSGRCode :: Bool -> [SGR] -> ShowS -> ShowS
withSGRCode useColour code content =
  if useColour then
    showString (setSGRCode code)
    . content
    . showString (setSGRCode [])
  else
    content

showExpectation :: [String] -> Maybe String -> ShowS
showExpectation [] Nothing = showString "no rule to match at end of input nodes"
showExpectation expected Nothing = showString "expected " . showSymbols expected . showString " at end of input nodes"
showExpectation expected (Just actual) = showString "expected " . showSymbols expected . showString ", but got " . showString actual

showSymbols :: [String] -> ShowS
showSymbols [] = showString "end of input nodes"
showSymbols [symbol] = showString symbol
showSymbols [a, b] = showString a . showString " or " . showString b
showSymbols [a, b, c] = showString a . showString ", " . showString b . showString ", or " . showString c
showSymbols (h:t) = showString h . showString ", " . showSymbols t

showSpan :: Maybe FilePath -> Info.Span -> ShowS
showSpan path Info.Span{..} = maybe (showParen True (showString "interactive")) showString path . showChar ':' . (if spanStart == spanEnd then showPos spanStart else showPos spanStart . showChar '-' . showPos spanEnd)
  where showPos Info.Pos{..} = shows posLine . showChar ':' . shows posColumn


firstSet :: Ix grammar => Assignment ast grammar a -> [grammar]
firstSet = iterFreer (\ assignment _ -> case assignment of
  Choose symbols _ -> symbols
  _ -> []) . ([] <$)


-- | Run an assignment over an AST exhaustively.
assignBy :: (Symbol grammar, Ix grammar, Eq ast, F.Recursive ast, Foldable (F.Base ast))
         => (forall x. F.Base ast x -> Node grammar) -- ^ A function to project a 'Node' from the ast.
         -> Source.Source                            -- ^ The source for the parse tree.
         -> Assignment ast grammar a                 -- ^ The 'Assignment to run.
         -> ast                                      -- ^ The root of the ast.
         -> Either (Error grammar) a                 -- ^ 'Either' an 'Error' or an assigned value.
assignBy toNode source assignment ast = bimap fst fst (runAssignment toNode source assignment (makeState [ast]))
{-# INLINE assignBy #-}

-- | Run an assignment of nodes in a grammar onto terms in a syntax over an AST exhaustively.
runAssignment :: forall grammar a ast. (Symbol grammar, Ix grammar, Eq ast, F.Recursive ast, Foldable (F.Base ast))
              => (forall x. F.Base ast x -> Node grammar)         -- ^ A function to project a 'Node' from the ast.
              -> Source.Source                                    -- ^ The source for the parse tree.
              -> Assignment ast grammar a                         -- ^ The 'Assignment' to run.
              -> State ast                                        -- ^ The current state.
              -> Either (Error grammar, State ast) (a, State ast) -- ^ 'Either' an 'Error' or an assigned value & updated state.
runAssignment toNode source = (\ assignment state -> go assignment state >>= requireExhaustive)
  -- Note: We explicitly bind toNode & source above in order to ensure that the where clause can close over them; they don’t change through the course of the run, so holding one reference is sufficient. On the other hand, we don’t want to accidentally capture the assignment and state in the where clause, since they change at every step—and capturing when you meant to shadow is an easy mistake to make, & results in hard-to-debug errors. Binding them in a lambda avoids that problem while also being easier to follow than a pointfree definition.
  where go :: Assignment ast grammar result -> State ast -> Either (Error grammar, State ast) (result, State ast)
        go assignment = iterFreer run ((pure .) . (,) <$> assignment)
        {-# INLINE go #-}

        run :: AssignmentF ast grammar x
            -> (x -> State ast -> Either (Error grammar, State ast) (result, State ast))
            -> State ast
            -> Either (Error grammar, State ast) (result, State ast)
        run assignment yield initialState = assignment `seq` expectedSymbols `seq` state `seq` maybe (anywhere Nothing) (atNode . F.project) (listToMaybe stateNodes)
          where atNode node = case assignment of
                  Location -> yield (nodeLocation (toNode node)) state
                  Project projection -> yield (projection node) state
                  Source -> yield (Source.sourceBytes (Source.slice (nodeByteRange (toNode node)) source)) (advance state)
                  Children child -> do
                    (a, state') <- go child state { stateNodes = toList node } >>= requireExhaustive
                    yield a (advance state' { stateNodes = stateNodes })
                  Choose _ choices | symbol <- nodeSymbol (toNode node), inRange (bounds choices) symbol, Just choice <- choices ! symbol -> yield choice state
                  Catch during handler -> go during state `catchError` (flip go state . handler . fst) >>= uncurry yield
                  _ -> anywhere (Just node)

                anywhere node = case assignment of
                  End | Nothing <- node -> yield () state
                      | otherwise -> Left (makeError node, state)
                  Location -> yield (Info.Range stateOffset stateOffset :. Info.Span statePos statePos :. Nil) state
                  Many rule -> fix (\ recur state -> (go rule state >>= \ (a, state') -> first (a:) <$> if state == state' then pure ([], state') else recur state') `catchError` const (pure ([], state))) state >>= uncurry yield
                  Alt as -> sconcat (flip yield state <$> as)
                  Throw e -> Left (fromMaybe (makeError node) e, state)
                  Catch during _ -> go during state >>= uncurry yield
                  Choose{} -> Left (makeError node, state)
                  Project{} -> Left (makeError node, state)
                  Children{} -> Left (makeError node, state)
                  Source -> Left (makeError node, state)
                  Label child _ -> go child state >>= uncurry yield

                state@State{..} = if not (null expectedSymbols) && all ((== Regular) . symbolType) expectedSymbols then dropAnonymous initialState else initialState
                expectedSymbols = firstSet (assignment `Then` return)
                makeError :: HasCallStack => Maybe (F.Base ast ast) -> Error grammar
                makeError node = maybe (Error (Info.Span statePos statePos) expectedSymbols Nothing) (nodeError expectedSymbols . toNode) node

        requireExhaustive :: HasCallStack => (result, State ast) -> Either (Error grammar, State ast) (result, State ast)
        requireExhaustive (a, state) = let state' = dropAnonymous state in case stateNodes state' of
          [] -> Right (a, state')
          node : _ -> Left (nodeError [] (toNode (F.project node)), state')

        dropAnonymous state = state { stateNodes = dropWhile ((/= Regular) . symbolType . nodeSymbol . toNode . F.project) (stateNodes state) }

        -- Advances the state past the current (head) node (if any), dropping it off stateNodes, and updating stateOffset & statePos to its end; or else returns the state unchanged.
        advance state@State{..}
          | node : rest <- stateNodes
          , Node{..} <- toNode (F.project node) = State (Info.end nodeByteRange) (Info.spanEnd nodeSpan) rest
          | otherwise = state

-- | State kept while running 'Assignment's.
data State ast = State
  { stateOffset :: {-# UNPACK #-} !Int       -- ^ The offset into the Source thus far reached, measured in bytes.
  , statePos :: {-# UNPACK #-} !Info.Pos     -- ^ The (1-indexed) line/column position in the Source thus far reached.
  , stateNodes :: ![ast]                     -- ^ The remaining nodes to assign. Note that 'children' rules recur into subterms, and thus this does not necessarily reflect all of the terms remaining to be assigned in the overall algorithm, only those “in scope.”
  }
  deriving (Eq, Show)

makeState :: [ast] -> State ast
makeState = State 0 (Info.Pos 1 1)


-- Instances

instance Ix grammar => Alternative (Assignment ast grammar) where
  empty :: HasCallStack => Assignment ast grammar a
  empty = Throw Nothing `Then` return
  (<|>) :: HasCallStack => Assignment ast grammar a -> Assignment ast grammar a -> Assignment ast grammar a
  Return a <|> _ = Return a
  (Throw Nothing `Then` _) <|> r = r
  l <|> (Throw Nothing `Then` _) = l
  (Throw err `Then` continue) <|> _ = Throw err `Then` continue
  (Children l `Then` continueL) <|> (Children r `Then` continueR) = Children (Left <$> l <|> Right <$> r) `Then` either continueL continueR
  (Location `Then` continueL) <|> (Location `Then` continueR) = Location `Then` uncurry (<|>) . (continueL &&& continueR)
  (Source `Then` continueL) <|> (Source `Then` continueR) = Source `Then` uncurry (<|>) . (continueL &&& continueR)
  (Alt ls `Then` continueL) <|> (Alt rs `Then` continueR) = Alt ((Left <$> ls) <> (Right <$> rs)) `Then` either continueL continueR
  (Alt ls `Then` continueL) <|> r = Alt ((continueL <$> ls) <> pure r) `Then` id
  l <|> (Alt rs `Then` continueR) = Alt (l <| (continueR <$> rs)) `Then` id
  l <|> r | Just (sl, cl) <- choices l, Just (sr, cr) <- choices r = fromMaybe id (rewrapFor r) . fromMaybe id (rewrapFor l) $ Choose (sl `union` sr) (accumArray (\ a b -> liftA2 (<|>) a b <|> a <|> b) Nothing (unionBounds cl cr) (assocs cl <> assocs cr)) `Then` id
          | otherwise = wrap (Alt (l :| [r]))
    where choices :: Assignment ast grammar a -> Maybe ([grammar], Array grammar (Maybe (Assignment ast grammar a)))
          choices (Choose symbols choices `Then` continue) = Just (symbols, fmap continue <$> choices)
          choices (Many rule `Then` continue) = second (fmap ((Many rule `Then` continue) <$)) <$> choices rule
          choices (Catch during _ `Then` continue) = second (fmap (fmap (>>= continue))) <$> choices during
          choices _ = Nothing
          unionBounds a b = (min (uncurry min (bounds a)) (uncurry min (bounds b)), max (uncurry max (bounds a)) (uncurry max (bounds b)))
          rewrapFor :: Assignment ast grammar a -> Maybe (Assignment ast grammar a -> Assignment ast grammar a)
          rewrapFor (Many _ `Then` continue) = Just (<|> continue [])
          rewrapFor (Catch _ handler `Then` continue) = Just (`catchError` (continue <=< handler))
          rewrapFor _ = Nothing
  many :: HasCallStack => Assignment ast grammar a -> Assignment ast grammar [a]
  many a = Many a `Then` return

instance (Ix grammar, Show grammar) => Parsing (Assignment ast grammar) where
  try = id

  (<?>) :: HasCallStack => Assignment ast grammar a -> String -> Assignment ast grammar a
  a <?> s = withFrozenCallStack $ Label a s `Then` return

  unexpected = const empty

  eof :: HasCallStack => Assignment ast grammar ()
  eof = withFrozenCallStack $ End `Then` return

  notFollowedBy :: (HasCallStack, Show a) => Assignment ast grammar a -> Assignment ast grammar ()
  notFollowedBy a = withFrozenCallStack $ a *> unexpected (show a) <|> pure ()

instance MonadError (Error grammar) (Assignment ast grammar) where
  throwError :: HasCallStack => Error grammar -> Assignment ast grammar a
  throwError error = withFrozenCallStack $ Throw (Just error) `Then` return

  catchError :: HasCallStack => Assignment ast grammar a -> (Error grammar -> Assignment ast grammar a) -> Assignment ast grammar a
  catchError during handler = withFrozenCallStack $ Catch during handler `Then` return

instance (Ix grammar, Show grammar) => Show1 (AssignmentF ast grammar) where
  liftShowsPrec sp sl d a = case a of
    End -> showString "End" . showChar ' ' . sp d ()
    Location -> showString "Location" . sp d (Info.Range 0 0 :. Info.Span (Info.Pos 1 1) (Info.Pos 1 1) :. Nil)
    Project projection -> showsUnaryWith (const (const (showChar '_'))) "Project" d projection
    Source -> showString "Source" . showChar ' ' . sp d ""
    Children a -> showsUnaryWith (liftShowsPrec sp sl) "Children" d a
    Choose symbols choices -> showsBinaryWith showsPrec (const (liftShowList sp sl)) "Choose" d symbols ((choices !) <$> symbols)
    Many a -> showsUnaryWith (liftShowsPrec (\ d a -> sp d [a]) (sl . pure)) "Many" d a
    Alt as -> showsUnaryWith (const sl) "Alt" d (toList as)
    Throw e -> showsUnaryWith showsPrec "Throw" d e
    Catch during handler -> showsBinaryWith (liftShowsPrec sp sl) (const (const (showChar '_'))) "Catch" d during handler
    Label child string -> showsBinaryWith (liftShowsPrec sp sl) showsPrec "Label" d child string
