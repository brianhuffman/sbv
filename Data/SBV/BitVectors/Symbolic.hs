-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.BitVectors.Symbolic
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Symbolic values
-----------------------------------------------------------------------------

{-# LANGUAGE    GeneralizedNewtypeDeriving #-}
{-# LANGUAGE    TypeSynonymInstances       #-}
{-# LANGUAGE    TypeOperators              #-}
{-# LANGUAGE    MultiParamTypeClasses      #-}
{-# LANGUAGE    ScopedTypeVariables        #-}
{-# LANGUAGE    FlexibleInstances          #-}
{-# LANGUAGE    PatternGuards              #-}
{-# LANGUAGE    DefaultSignatures          #-}
{-# LANGUAGE    NamedFieldPuns             #-}
{-# LANGUAGE    DeriveDataTypeable         #-}
{-# LANGUAGE    CPP                        #-}
{-# OPTIONS_GHC -fno-warn-orphans          #-}

module Data.SBV.BitVectors.Symbolic
  ( NodeId(..)
  , SW(..), swKind, trueSW, falseSW
  , Op(..), smtLibSquareRoot, smtLibFusedMA
  , Quantifier(..), needsExistentials
  , RoundingMode(..)
  , SBVType(..), newUninterpreted, unintFnUIKind, addAxiom
  , SVal(..), svKind
  , svBitSize, svSigned
  , svMkSymVar
  , ArrayContext(..), ArrayInfo, arrayUIKind
  , svToSW, svToSymSW, forceSWArg
  , SBVExpr(..), newExpr
  , Cached, cache, uncache
  , ArrayIndex, uncacheAI
  , NamedSymVar
  , UnintKind(..)
  , getSValPathCondition, extendSValPathCondition
  , getTableIndex
  , SBVPgm(..), Symbolic, runSymbolic, runSymbolic', State
  , inProofMode, SBVRunMode(..), Result(..)
  , Logic(..), SMTLibLogic(..)
  , getTraceInfo, getConstraints
  , addSValConstraint
  , SMTLibPgm(..), SMTLibVersion(..)
  , SolverCapabilities(..)
  , extractSymbolicSimulationState
  , SMTScript(..), Solver(..), SMTSolver(..), SMTResult(..), SMTModel(..), SMTConfig(..), getSBranchRunConfig
  , outputSVal
  , mkSValUserSort
  , SArr(..), readSArr, resetSArr, writeSArr, mergeSArr, newSArr, eqSArr
  ) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative  (Applicative)
#endif

import Control.DeepSeq      (NFData(..))
import Control.Monad        (when, unless)
import Control.Monad.Reader (MonadReader, ReaderT, ask, runReaderT)
import Control.Monad.Trans  (MonadIO, liftIO)
import Data.Char            (isAlpha, isAlphaNum)
import Data.IORef           (IORef, newIORef, modifyIORef, readIORef, writeIORef)
import Data.List            (intercalate, sortBy)
import Data.Maybe           (isJust, fromJust, fromMaybe)

import qualified Data.Generics as G    (Data(..))
import qualified Data.Typeable as T    (Typeable)
import qualified Data.IntMap   as IMap (IntMap, empty, size, toAscList, lookup, insert, insertWith)
import qualified Data.Map      as Map  (Map, empty, toList, size, insert, lookup)
import qualified Data.Set      as Set  (Set, empty, toList, insert)
import qualified Data.Foldable as F    (toList)
import qualified Data.Sequence as S    (Seq, empty, (|>))

import System.Exit           (ExitCode(..))
import System.Mem.StableName
import System.Random

import Data.SBV.BitVectors.Kind
import Data.SBV.BitVectors.Concrete

-- | A symbolic node id
newtype NodeId = NodeId Int deriving (Eq, Ord)

-- | A symbolic word, tracking it's signedness and size.
data SW = SW Kind NodeId deriving (Eq, Ord)

instance Show SW where
  show (SW _ (NodeId n))
    | n < 0 = "s_" ++ show (abs n)
    | True  = 's' : show n

-- | Kind of a symbolic word.
swKind :: SW -> Kind
swKind (SW k _) = k

-- | Forcing an argument; this is a necessary evil to make sure all the arguments
-- to an uninterpreted function and sBranch test conditions are evaluated before called;
-- the semantics of uinterpreted functions is necessarily strict; deviating from Haskell's
forceSWArg :: SW -> IO ()
forceSWArg (SW k n) = k `seq` n `seq` return ()

-- | Constant False as a SW. Note that this value always occupies slot -2.
falseSW :: SW
falseSW = SW KBool $ NodeId (-2)

-- | Constant False as a SW. Note that this value always occupies slot -1.
trueSW :: SW
trueSW  = SW KBool $ NodeId (-1)

-- | Symbolic operations
data Op = Plus | Times | Minus | UNeg | Abs
        | Quot | Rem
        | Equal | NotEqual
        | LessThan | GreaterThan | LessEq | GreaterEq
        | Ite
        | And | Or  | XOr | Not
        | Shl Int | Shr Int | Rol Int | Ror Int
        | Extract Int Int -- Extract i j: extract bits i to j. Least significant bit is 0 (big-endian)
        | Join  -- Concat two words to form a bigger one, in the order given
        | LkUp (Int, Kind, Kind, Int) !SW !SW   -- (table-index, arg-type, res-type, length of the table) index out-of-bounds-value
        | ArrEq   Int Int
        | ArrRead Int
        | Uninterpreted String
        -- Floating point uops with custom rounding-modes
        | FPRound String
        deriving (Eq, Ord)

-- | SMT-Lib's square-root over floats/doubles. We piggy back on to the uninterpreted function mechanism
-- to implement these; which is not a terrible idea; although the use of the constructor 'Uninterpreted'
-- might be confusing. This function will *not* be uninterpreted in reality, as QF_FP will define it. It's
-- a bit of a shame, but much easier to implement it this way.
smtLibSquareRoot :: Op
smtLibSquareRoot = Uninterpreted "fp.sqrt"

-- | SMT-Lib's fusedMA over floats/doubles. Similar to the 'smtLibSquareRoot'. Note that we cannot implement
-- this function in Haskell as precision loss would be inevitable. Maybe Haskell will eventually add this op
-- to the Num class.
smtLibFusedMA :: Op
smtLibFusedMA = Uninterpreted "fp.fma"

-- | Show instance for 'Op'. Note that this is largely for debugging purposes, not used
-- for being read by any tool.
instance Show Op where
  show (Shl i) = "<<"  ++ show i
  show (Shr i) = ">>"  ++ show i
  show (Rol i) = "<<<" ++ show i
  show (Ror i) = ">>>" ++ show i
  show (Extract i j) = "choose [" ++ show i ++ ":" ++ show j ++ "]"
  show (LkUp (ti, at, rt, l) i e)
        = "lookup(" ++ tinfo ++ ", " ++ show i ++ ", " ++ show e ++ ")"
        where tinfo = "table" ++ show ti ++ "(" ++ show at ++ " -> " ++ show rt ++ ", " ++ show l ++ ")"
  show (ArrEq i j)   = "array_" ++ show i ++ " == array_" ++ show j
  show (ArrRead i)   = "select array_" ++ show i
  show (Uninterpreted i) = "[uninterpreted] " ++ i
  show (FPRound w)       = w
  show op
    | Just s <- op `lookup` syms = s
    | True                       = error "impossible happened; can't find op!"
    where syms = [ (Plus, "+"), (Times, "*"), (Minus, "-"), (UNeg, "-"), (Abs, "abs")
                 , (Quot, "quot")
                 , (Rem,  "rem")
                 , (Equal, "=="), (NotEqual, "/=")
                 , (LessThan, "<"), (GreaterThan, ">"), (LessEq, "<"), (GreaterEq, ">")
                 , (Ite, "if_then_else")
                 , (And, "&"), (Or, "|"), (XOr, "^"), (Not, "~")
                 , (Join, "#")
                 ]

-- | Quantifiers: forall or exists. Note that we allow
-- arbitrary nestings.
data Quantifier = ALL | EX deriving Eq

-- | Are there any existential quantifiers?
needsExistentials :: [Quantifier] -> Bool
needsExistentials = (EX `elem`)

-- | A simple type for SBV computations, used mainly for uninterpreted constants.
-- We keep track of the signedness/size of the arguments. A non-function will
-- have just one entry in the list.
newtype SBVType = SBVType [Kind]
             deriving (Eq, Ord)

-- | how many arguments does the type take?
typeArity :: SBVType -> Int
typeArity (SBVType xs) = length xs - 1

instance Show SBVType where
  show (SBVType []) = error "SBV: internal error, empty SBVType"
  show (SBVType xs) = intercalate " -> " $ map show xs

-- | A symbolic expression
data SBVExpr = SBVApp !Op ![SW]
             deriving (Eq, Ord)

-- | To improve hash-consing, take advantage of commutative operators by
-- reordering their arguments.
reorder :: SBVExpr -> SBVExpr
reorder s = case s of
              SBVApp op [a, b] | isCommutative op && a > b -> SBVApp op [b, a]
              _ -> s
  where isCommutative :: Op -> Bool
        isCommutative o = o `elem` [Plus, Times, Equal, NotEqual, And, Or, XOr]

-- | Show instance for 'SBVExpr'. Again, only for debugging purposes.
instance Show SBVExpr where
  show (SBVApp Ite [t, a, b]) = unwords ["if", show t, "then", show a, "else", show b]
  show (SBVApp (Shl i) [a])   = unwords [show a, "<<", show i]
  show (SBVApp (Shr i) [a])   = unwords [show a, ">>", show i]
  show (SBVApp (Rol i) [a])   = unwords [show a, "<<<", show i]
  show (SBVApp (Ror i) [a])   = unwords [show a, ">>>", show i]
  show (SBVApp op  [a, b])    = unwords [show a, show op, show b]
  show (SBVApp op  args)      = unwords (show op : map show args)

-- | A program is a sequence of assignments
newtype SBVPgm = SBVPgm {pgmAssignments :: S.Seq (SW, SBVExpr)}

-- | 'NamedSymVar' pairs symbolic words and user given/automatically generated names
type NamedSymVar = (SW, String)

-- | 'UnintKind' pairs array names and uninterpreted constants with their "kinds"
-- used mainly for printing counterexamples
data UnintKind = UFun Int String | UArr Int String      -- in each case, arity and the aliasing name
 deriving Show

-- | Result of running a symbolic computation
data Result = Result (Set.Set Kind)                -- kinds used in the program
                     [(String, CW)]                -- quick-check counter-example information (if any)
                     [(String, [String])]          -- uninterpeted code segments
                     [(Quantifier, NamedSymVar)]   -- inputs (possibly existential)
                     [(SW, CW)]                    -- constants
                     [((Int, Kind, Kind), [SW])]   -- tables (automatically constructed) (tableno, index-type, result-type) elts
                     [(Int, ArrayInfo)]            -- arrays (user specified)
                     [(String, SBVType)]           -- uninterpreted constants
                     [(String, [String])]          -- axioms
                     SBVPgm                        -- assignments
                     [SW]                          -- additional constraints (boolean)
                     [SW]                          -- outputs

-- | Extract the constraints from a result
getConstraints :: Result -> [SW]
getConstraints (Result _ _ _ _ _ _ _ _ _ _ cstrs _) = cstrs

-- | Extract the traced-values from a result (quick-check)
getTraceInfo :: Result -> [(String, CW)]
getTraceInfo (Result _ tvals _ _ _ _ _ _ _ _ _ _) = tvals

-- | Show instance for 'Result'. Only for debugging purposes.
instance Show Result where
  show (Result _ _ _ _ cs _ _ [] [] _ [] [r])
    | Just c <- r `lookup` cs
    = show c
  show (Result kinds _ cgs is cs ts as uis axs xs cstrs os)  = intercalate "\n" $
                   (if null usorts then [] else "SORTS" : map ("  " ++) usorts)
                ++ ["INPUTS"]
                ++ map shn is
                ++ ["CONSTANTS"]
                ++ map shc cs
                ++ ["TABLES"]
                ++ map sht ts
                ++ ["ARRAYS"]
                ++ map sha as
                ++ ["UNINTERPRETED CONSTANTS"]
                ++ map shui uis
                ++ ["USER GIVEN CODE SEGMENTS"]
                ++ concatMap shcg cgs
                ++ ["AXIOMS"]
                ++ map shax axs
                ++ ["DEFINE"]
                ++ map (\(s, e) -> "  " ++ shs s ++ " = " ++ show e) (F.toList (pgmAssignments xs))
                ++ ["CONSTRAINTS"]
                ++ map (("  " ++) . show) cstrs
                ++ ["OUTPUTS"]
                ++ map (("  " ++) . show) os
    where usorts = [sh s t | KUserSort s t <- Set.toList kinds]
                   where sh s (Left   _, _) = s
                         sh s (Right es, _) = s ++ " (" ++ intercalate ", " es ++ ")"
          shs sw = show sw ++ " :: " ++ show (swKind sw)
          sht ((i, at, rt), es)  = "  Table " ++ show i ++ " : " ++ show at ++ "->" ++ show rt ++ " = " ++ show es
          shc (sw, cw) = "  " ++ show sw ++ " = " ++ show cw
          shcg (s, ss) = ("Variable: " ++ s) : map ("  " ++) ss
          shn (q, (sw, nm)) = "  " ++ ni ++ " :: " ++ show (swKind sw) ++ ex ++ alias
            where ni = show sw
                  ex | q == ALL = ""
                     | True     = ", existential"
                  alias | ni == nm = ""
                        | True     = ", aliasing " ++ show nm
          sha (i, (nm, (ai, bi), ctx)) = "  " ++ ni ++ " :: " ++ show ai ++ " -> " ++ show bi ++ alias
                                       ++ "\n     Context: "     ++ show ctx
            where ni = "array_" ++ show i
                  alias | ni == nm = ""
                        | True     = ", aliasing " ++ show nm
          shui (nm, t) = "  [uninterpreted] " ++ nm ++ " :: " ++ show t
          shax (nm, ss) = "  -- user defined axiom: " ++ nm ++ "\n  " ++ intercalate "\n  " ss

-- | The context of a symbolic array as created
data ArrayContext = ArrayFree (Maybe SW)     -- ^ A new array, with potential initializer for each cell
                  | ArrayReset Int SW        -- ^ An array created from another array by fixing each element to another value
                  | ArrayMutate Int SW SW    -- ^ An array created by mutating another array at a given cell
                  | ArrayMerge  SW Int Int   -- ^ An array created by symbolically merging two other arrays

instance Show ArrayContext where
  show (ArrayFree Nothing)  = " initialized with random elements"
  show (ArrayFree (Just s)) = " initialized with " ++ show s ++ " :: " ++ show (swKind s)
  show (ArrayReset i s)     = " reset array_" ++ show i ++ " with " ++ show s ++ " :: " ++ show (swKind s)
  show (ArrayMutate i a b)  = " cloned from array_" ++ show i ++ " with " ++ show a ++ " :: " ++ show (swKind a) ++ " |-> " ++ show b ++ " :: " ++ show (swKind b)
  show (ArrayMerge s i j)   = " merged arrays " ++ show i ++ " and " ++ show j ++ " on condition " ++ show s

-- | Expression map, used for hash-consing
type ExprMap   = Map.Map SBVExpr SW

-- | Constants are stored in a map, for hash-consing
type CnstMap   = Map.Map CW SW

-- | Kinds used in the program; used for determining the final SMT-Lib logic to pick
type KindSet = Set.Set Kind

-- | Tables generated during a symbolic run
type TableMap  = Map.Map [SW] (Int, Kind, Kind)

-- | Representation for symbolic arrays
type ArrayInfo = (String, (Kind, Kind), ArrayContext)

-- | Arrays generated during a symbolic run
type ArrayMap  = IMap.IntMap ArrayInfo

-- | Uninterpreted-constants generated during a symbolic run
type UIMap     = Map.Map String SBVType

-- | Code-segments for Uninterpreted-constants, as given by the user
type CgMap     = Map.Map String [String]

-- | Cached values, implementing sharing
type Cache a   = IMap.IntMap [(StableName (State -> IO a), a)]

-- | Convert an SBV-type to the kind-of uninterpreted value it represents
unintFnUIKind :: (String, SBVType) -> (String, UnintKind)
unintFnUIKind (s, t) = (s, UFun (typeArity t) s)

-- | Convert an array value type to the kind-of uninterpreted value it represents
arrayUIKind :: (Int, ArrayInfo) -> Maybe (String, UnintKind)
arrayUIKind (i, (nm, _, ctx))
  | external ctx = Just ("array_" ++ show i, UArr 1 nm) -- arrays are always 1-dimensional in the SMT-land. (Unless encoded explicitly)
  | True         = Nothing
  where external (ArrayFree{})   = True
        external (ArrayReset{})  = False
        external (ArrayMutate{}) = False
        external (ArrayMerge{})  = False

-- | Different means of running a symbolic piece of code
data SBVRunMode = Proof (Bool, Maybe SMTConfig) -- ^ Symbolic simulation mode, for proof purposes. Bool is True if it's a sat instance. SMTConfig is used for 'sBranch' calls.
                | CodeGen                       -- ^ Code generation mode
                | Concrete StdGen               -- ^ Concrete simulation mode. The StdGen is for the pConstrain acceptance in cross runs

-- | Is this a concrete run? (i.e., quick-check or test-generation like)
isConcreteMode :: SBVRunMode -> Bool
isConcreteMode (Concrete _) = True
isConcreteMode (Proof{})    = False
isConcreteMode CodeGen      = False

-- | The state of the symbolic interpreter
data State  = State { runMode       :: SBVRunMode
                    , pathCond      :: SVal -- ^ kind KBool
                    , rStdGen       :: IORef StdGen
                    , rCInfo        :: IORef [(String, CW)]
                    , rctr          :: IORef Int
                    , rUsedKinds    :: IORef KindSet
                    , rinps         :: IORef [(Quantifier, NamedSymVar)]
                    , rConstraints  :: IORef [SW]
                    , routs         :: IORef [SW]
                    , rtblMap       :: IORef TableMap
                    , spgm          :: IORef SBVPgm
                    , rconstMap     :: IORef CnstMap
                    , rexprMap      :: IORef ExprMap
                    , rArrayMap     :: IORef ArrayMap
                    , rUIMap        :: IORef UIMap
                    , rCgMap        :: IORef CgMap
                    , raxioms       :: IORef [(String, [String])]
                    , rSWCache      :: IORef (Cache SW)
                    , rAICache      :: IORef (Cache Int)
                    }

-- | Get the current path condition
getSValPathCondition :: State -> SVal
getSValPathCondition = pathCond

-- | Extend the path condition with the given test value.
extendSValPathCondition :: State -> (SVal -> SVal) -> State
extendSValPathCondition st f = st{pathCond = f (pathCond st)}

-- | Are we running in proof mode?
inProofMode :: State -> Bool
inProofMode s = case runMode s of
                  Proof{}    -> True
                  CodeGen    -> False
                  Concrete{} -> False

-- | If in proof mode, get the underlying configuration (used for 'sBranch')
getSBranchRunConfig :: State -> Maybe SMTConfig
getSBranchRunConfig st = case runMode st of
                           Proof (_, s)  -> s
                           _             -> Nothing

-- | The "Symbolic" value. Either a constant (@Left@) or a symbolic
-- value (@Right Cached@). Note that caching is essential for making
-- sure sharing is preserved.
data SVal = SVal !Kind !(Either CW (Cached SW))

-- | Extract the 'Kind'.
svKind :: SVal -> Kind
svKind (SVal k _) = k

-- | Extract the but-size from the kind. Assumption: Only called
-- on kinds that have an associated size. (i.e., no 'SFloat'/'SDouble' etc.)
svBitSize :: SVal -> Int
svBitSize x =
  case svKind x of
    KBounded _ s  -> s
    _             -> error $ "svBitSize: invalid kind " ++ show (svKind x)

-- | Is the value signed?
svSigned :: SVal -> Bool
svSigned x = kindHasSign (svKind x)

-- | Show instance for 'SVal'. Not particularly "desirable", but will do if needed
instance Show SVal where
  show (SVal _ (Left c))  = show c
  show (SVal k (Right _)) = "<symbolic> :: " ++ show k

-- | Equality constraint on SBV values. Not desirable since we can't really compare two
-- symbolic values, but will do.
instance Eq SVal where
  SVal _ (Left a) == SVal _ (Left b) = a == b
  a == b = error $ "Comparing symbolic bit-vectors; Use (.==) instead. Received: " ++ show (a, b)
  SVal _ (Left a) /= SVal _ (Left b) = a /= b
  a /= b = error $ "Comparing symbolic bit-vectors; Use (./=) instead. Received: " ++ show (a, b)

-- | Increment the variable counter
incCtr :: State -> IO Int
incCtr s = do ctr <- readIORef (rctr s)
              let i = ctr + 1
              i `seq` writeIORef (rctr s) i
              return ctr

-- | Generate a random value, for quick-check and test-gen purposes
throwDice :: State -> IO Double
throwDice st = do g <- readIORef (rStdGen st)
                  let (r, g') = randomR (0, 1) g
                  writeIORef (rStdGen st) g'
                  return r

-- | Create a new uninterpreted symbol, possibly with user given code
newUninterpreted :: State -> String -> SBVType -> Maybe [String] -> IO ()
newUninterpreted st nm t mbCode
  | null nm || not (isAlpha (head nm)) || not (all validChar (tail nm))
  = error $ "Bad uninterpreted constant name: " ++ show nm ++ ". Must be a valid identifier."
  | True = do
        uiMap <- readIORef (rUIMap st)
        case nm `Map.lookup` uiMap of
          Just t' -> when (t /= t') $ error $  "Uninterpreted constant " ++ show nm ++ " used at incompatible types\n"
                                            ++ "      Current type      : " ++ show t ++ "\n"
                                            ++ "      Previously used at: " ++ show t'
          Nothing -> do modifyIORef (rUIMap st) (Map.insert nm t)
                        when (isJust mbCode) $ modifyIORef (rCgMap st) (Map.insert nm (fromJust mbCode))
  where validChar x = isAlphaNum x || x `elem` "_"

-- | Create a new SW
newSW :: State -> Kind -> IO (SW, String)
newSW st k = do ctr <- incCtr st
                let sw = SW k (NodeId ctr)
                registerKind st k
                return (sw, 's' : show ctr)
{-# INLINE newSW #-}

-- | Register a new kind with the system, used for uninterpreted sorts. We try to avoid names that
-- might be conflicting with SMTLib; but this list is not comprehensive.. Beware!
registerKind :: State -> Kind -> IO ()
registerKind st k
  | KUserSort sortName _ <- k, sortName `elem` reserved
  = error $ "SBV: " ++ show sortName ++ " is a reserved sort; please use a different name."
  | True
  = modifyIORef (rUsedKinds st) (Set.insert k)
 where -- TODO: this list is not comprehensive!
       reserved = ["Int", "Real", "List", "Array", "Bool", "NUMERAL", "DECIMAL", "STRING", "FP", "FloatingPoint", "fp"]  -- Reserved by SMT-Lib

-- | Create a new constant; hash-cons as necessary
newConst :: State -> CW -> IO SW
newConst st c = do
  constMap <- readIORef (rconstMap st)
  case c `Map.lookup` constMap of
    Just sw -> return sw
    Nothing -> do let k = cwKind c
                  (sw, _) <- newSW st k
                  modifyIORef (rconstMap st) (Map.insert c sw)
                  return sw
{-# INLINE newConst #-}

-- | Create a new table; hash-cons as necessary
getTableIndex :: State -> Kind -> Kind -> [SW] -> IO Int
getTableIndex st at rt elts = do
  tblMap <- readIORef (rtblMap st)
  case elts `Map.lookup` tblMap of
    Just (i, _, _)  -> return i
    Nothing         -> do let i = Map.size tblMap
                          modifyIORef (rtblMap st) (Map.insert elts (i, at, rt))
                          return i

-- | Create a new expression; hash-cons as necessary
newExpr :: State -> Kind -> SBVExpr -> IO SW
newExpr st k app = do
   let e = reorder app
   exprMap <- readIORef (rexprMap st)
   case e `Map.lookup` exprMap of
     Just sw -> return sw
     Nothing -> do (sw, _) <- newSW st k
                   modifyIORef (spgm st)     (\(SBVPgm xs) -> SBVPgm (xs S.|> (sw, e)))
                   modifyIORef (rexprMap st) (Map.insert e sw)
                   return sw
{-# INLINE newExpr #-}

-- | Convert a symbolic value to a symbolic-word
svToSW :: State -> SVal -> IO SW
svToSW st (SVal _ (Left c))  = newConst st c
svToSW st (SVal _ (Right f)) = uncache f st

-- | Convert a symbolic value to an SW, inside the Symbolic monad
svToSymSW :: SVal -> Symbolic SW
svToSymSW sbv = do st <- ask
                   liftIO $ svToSW st sbv

-------------------------------------------------------------------------
-- * Symbolic Computations
-------------------------------------------------------------------------
-- | A Symbolic computation. Represented by a reader monad carrying the
-- state of the computation, layered on top of IO for creating unique
-- references to hold onto intermediate results.
newtype Symbolic a = Symbolic (ReaderT State IO a)
                   deriving (Applicative, Functor, Monad, MonadIO, MonadReader State)

-- | Create a symbolic value, based on the quantifier we have. If an
-- explicit quantifier is given, we just use that. If not, then we
-- pick existential for SAT calls and universal for everything else.
-- @randomCW@ is used for generating random values for this variable
-- when used for 'quickCheck' purposes.
svMkSymVar :: Maybe Quantifier -> Kind -> Maybe String -> Symbolic SVal
svMkSymVar mbQ k mbNm = do
        st <- ask
        let q = case (mbQ, runMode st) of
                  (Just x,  _)                -> x   -- user given, just take it
                  (Nothing, Concrete{})       -> ALL -- concrete simulation, pick universal
                  (Nothing, Proof (True, _))  -> EX  -- sat mode, pick existential
                  (Nothing, Proof (False, _)) -> ALL -- proof mode, pick universal
                  (Nothing, CodeGen)          -> ALL -- code generation, pick universal
        case runMode st of
          Concrete _ | q == EX -> case mbNm of
                                    Nothing -> error $ "Cannot quick-check in the presence of existential variables, type: " ++ show k
                                    Just nm -> error $ "Cannot quick-check in the presence of existential variable " ++ nm ++ " :: " ++ show k
          Concrete _           -> do cw <- liftIO (randomCW k)
                                     liftIO $ modifyIORef (rCInfo st) ((fromMaybe "_" mbNm, cw):)
                                     return (SVal k (Left cw))
          _          -> do (sw, internalName) <- liftIO $ newSW st k
                           let nm = fromMaybe internalName mbNm
                           liftIO $ modifyIORef (rinps st) ((q, (sw, nm)):)
                           return $ SVal k $ Right $ cache (const (return sw))

-- | Create a properly quantified variable of a user defined sort. Only valid
-- in proof contexts.
mkSValUserSort :: Kind -> Maybe Quantifier -> Maybe String -> Symbolic SVal
mkSValUserSort k mbQ mbNm = do
        st <- ask
        let (KUserSort sortName _) = k
        liftIO $ registerKind st k
        let q = case (mbQ, runMode st) of
                  (Just x,  _)                -> x
                  (Nothing, Proof (True, _))  -> EX
                  (Nothing, Proof (False, _)) -> ALL
                  (Nothing, Concrete{})       -> error $ "SBV: Uninterpreted sort " ++ sortName ++ " can not be used in concrete simulation mode."
                  (Nothing, CodeGen)          -> error $ "SBV: Uninterpreted sort " ++ sortName ++ " can not be used in code-generation mode."
        ctr <- liftIO $ incCtr st
        let sw = SW k (NodeId ctr)
            nm = fromMaybe ('s':show ctr) mbNm
        liftIO $ modifyIORef (rinps st) ((q, (sw, nm)):)
        return $ SVal k $ Right $ cache (const (return sw))

-- | Add a user specified axiom to the generated SMT-Lib file. The first argument is a mere
-- string, use for commenting purposes. The second argument is intended to hold the multiple-lines
-- of the axiom text as expressed in SMT-Lib notation. Note that we perform no checks on the axiom
-- itself, to see whether it's actually well-formed or is sensical by any means.
-- A separate formalization of SMT-Lib would be very useful here.
addAxiom :: String -> [String] -> Symbolic ()
addAxiom nm ax = do
        st <- ask
        liftIO $ modifyIORef (raxioms st) ((nm, ax) :)

-- | Run a symbolic computation in Proof mode and return a 'Result'. The boolean
-- argument indicates if this is a sat instance or not.
runSymbolic :: (Bool, Maybe SMTConfig) -> Symbolic a -> IO Result
runSymbolic b c = snd `fmap` runSymbolic' (Proof b) c

-- | Run a symbolic computation, and return a extra value paired up with the 'Result'
runSymbolic' :: SBVRunMode -> Symbolic a -> IO (a, Result)
runSymbolic' currentRunMode (Symbolic c) = do
   ctr       <- newIORef (-2) -- start from -2; False and True will always occupy the first two elements
   cInfo     <- newIORef []
   pgm       <- newIORef (SBVPgm S.empty)
   emap      <- newIORef Map.empty
   cmap      <- newIORef Map.empty
   inps      <- newIORef []
   outs      <- newIORef []
   tables    <- newIORef Map.empty
   arrays    <- newIORef IMap.empty
   uis       <- newIORef Map.empty
   cgs       <- newIORef Map.empty
   axioms    <- newIORef []
   swCache   <- newIORef IMap.empty
   aiCache   <- newIORef IMap.empty
   usedKinds <- newIORef Set.empty
   cstrs     <- newIORef []
   rGen      <- case currentRunMode of
                  Concrete g -> newIORef g
                  _          -> newStdGen >>= newIORef
   let st = State { runMode      = currentRunMode
                  , pathCond     = SVal KBool (Left trueCW)
                  , rStdGen      = rGen
                  , rCInfo       = cInfo
                  , rctr         = ctr
                  , rUsedKinds   = usedKinds
                  , rinps        = inps
                  , routs        = outs
                  , rtblMap      = tables
                  , spgm         = pgm
                  , rconstMap    = cmap
                  , rArrayMap    = arrays
                  , rexprMap     = emap
                  , rUIMap       = uis
                  , rCgMap       = cgs
                  , raxioms      = axioms
                  , rSWCache     = swCache
                  , rAICache     = aiCache
                  , rConstraints = cstrs
                  }
   _ <- newConst st falseCW -- s(-2) == falseSW
   _ <- newConst st trueCW  -- s(-1) == trueSW
   r <- runReaderT c st
   res <- extractSymbolicSimulationState st
   return (r, res)

-- | Grab the program from a running symbolic simulation state. This is useful for internal purposes, for
-- instance when implementing 'sBranch'.
extractSymbolicSimulationState :: State -> IO Result
extractSymbolicSimulationState st@State{ spgm=pgm, rinps=inps, routs=outs, rtblMap=tables, rArrayMap=arrays, rUIMap=uis, raxioms=axioms
                                       , rUsedKinds=usedKinds, rCgMap=cgs, rCInfo=cInfo, rConstraints = cstrs} = do
   SBVPgm rpgm  <- readIORef pgm
   inpsO <- reverse `fmap` readIORef inps
   outsO <- reverse `fmap` readIORef outs
   let swap (a, b) = (b, a)
       cmp  (a, _) (b, _) = a `compare` b
   cnsts <- (sortBy cmp . map swap . Map.toList) `fmap` readIORef (rconstMap st)
   tbls  <- (sortBy (\((x, _, _), _) ((y, _, _), _) -> x `compare` y) . map swap . Map.toList) `fmap` readIORef tables
   arrs  <- IMap.toAscList `fmap` readIORef arrays
   unint <- Map.toList `fmap` readIORef uis
   axs   <- reverse `fmap` readIORef axioms
   knds  <- readIORef usedKinds
   cgMap <- Map.toList `fmap` readIORef cgs
   traceVals <- reverse `fmap` readIORef cInfo
   extraCstrs <- reverse `fmap` readIORef cstrs
   return $ Result knds traceVals cgMap inpsO cnsts tbls arrs unint axs (SBVPgm rpgm) extraCstrs outsO

-- | Handling constraints
imposeConstraint :: SVal -> Symbolic ()
imposeConstraint c = do st <- ask
                        case runMode st of
                          CodeGen -> error "SBV: constraints are not allowed in code-generation"
                          _       -> liftIO $ do v <- svToSW st c
                                                 modifyIORef (rConstraints st) (v:)

-- | Add a constraint with a given probability
addSValConstraint :: Maybe Double -> SVal -> SVal -> Symbolic ()
addSValConstraint Nothing  c _  = imposeConstraint c
addSValConstraint (Just t) c c'
  | t < 0 || t > 1
  = error $ "SBV: pConstrain: Invalid probability threshold: " ++ show t ++ ", must be in [0, 1]."
  | True
  = do st <- ask
       unless (isConcreteMode (runMode st)) $ error "SBV: pConstrain only allowed in 'genTest' or 'quickCheck' contexts."
       case () of
         () | t > 0 && t < 1 -> liftIO (throwDice st) >>= \d -> imposeConstraint (if d <= t then c else c')
            | t > 0          -> imposeConstraint c
            | True           -> imposeConstraint c'

-- | Mark an interim result as an output. Useful when constructing Symbolic programs
-- that return multiple values, or when the result is programmatically computed.
outputSVal :: SVal -> Symbolic ()
outputSVal (SVal _ (Left c)) = do
  st <- ask
  sw <- liftIO $ newConst st c
  liftIO $ modifyIORef (routs st) (sw:)
outputSVal (SVal _ (Right f)) = do
  st <- ask
  sw <- liftIO $ uncache f st
  liftIO $ modifyIORef (routs st) (sw:)

---------------------------------------------------------------------------------
-- * Symbolic Arrays
---------------------------------------------------------------------------------

-- | Arrays implemented in terms of SMT-arrays: <http://smtlib.cs.uiowa.edu/theories/ArraysEx.smt2>
--
--   * Maps directly to SMT-lib arrays
--
--   * Reading from an unintialized value is OK and yields an unspecified result
--
--   * Can check for equality of these arrays
--
--   * Cannot quick-check theorems using @SArr@ values
--
--   * Typically slower as it heavily relies on SMT-solving for the array theory
--

data SArr = SArr (Kind, Kind) (Cached ArrayIndex)

-- | Read the array element at @a@
readSArr :: SArr -> SVal -> SVal
readSArr (SArr (_, bk) f) a = SVal bk $ Right $ cache r
  where r st = do arr <- uncacheAI f st
                  i   <- svToSW st a
                  newExpr st bk (SBVApp (ArrRead arr) [i])

-- | Reset all the elements of the array to the value @b@
resetSArr :: SArr -> SVal -> SArr
resetSArr (SArr ainfo f) b = SArr ainfo $ cache g
  where g st = do amap <- readIORef (rArrayMap st)
                  val <- svToSW st b
                  i <- uncacheAI f st
                  let j = IMap.size amap
                  j `seq` modifyIORef (rArrayMap st) (IMap.insert j ("array_" ++ show j, ainfo, ArrayReset i val))
                  return j

-- | Update the element at @a@ to be @b@
writeSArr :: SArr -> SVal -> SVal -> SArr
writeSArr (SArr ainfo f) a b = SArr ainfo $ cache g
  where g st = do arr  <- uncacheAI f st
                  addr <- svToSW st a
                  val  <- svToSW st b
                  amap <- readIORef (rArrayMap st)
                  let j = IMap.size amap
                  j `seq` modifyIORef (rArrayMap st) (IMap.insert j ("array_" ++ show j, ainfo, ArrayMutate arr addr val))
                  return j

-- | Merge two given arrays on the symbolic condition
-- Intuitively: @mergeArrays cond a b = if cond then a else b@.
-- Merging pushes the if-then-else choice down on to elements
mergeSArr :: SVal -> SArr -> SArr -> SArr
mergeSArr t (SArr ainfo a) (SArr _ b) = SArr ainfo $ cache h
  where h st = do ai <- uncacheAI a st
                  bi <- uncacheAI b st
                  ts <- svToSW st t
                  amap <- readIORef (rArrayMap st)
                  let k = IMap.size amap
                  k `seq` modifyIORef (rArrayMap st) (IMap.insert k ("array_" ++ show k, ainfo, ArrayMerge ts ai bi))
                  return k

-- | Create a named new array, with an optional initial value
newSArr :: (Kind, Kind) -> (Int -> String) -> Maybe SVal -> Symbolic SArr
newSArr ainfo mkNm mbInit = do
    st <- ask
    amap <- liftIO $ readIORef $ rArrayMap st
    let i = IMap.size amap
        nm = mkNm i
    actx <- liftIO $ case mbInit of
                       Nothing   -> return $ ArrayFree Nothing
                       Just ival -> svToSW st ival >>= \sw -> return $ ArrayFree (Just sw)
    liftIO $ modifyIORef (rArrayMap st) (IMap.insert i (nm, ainfo, actx))
    return $ SArr ainfo $ cache $ const $ return i

-- | Compare two arrays for equality
eqSArr :: SArr -> SArr -> SVal
eqSArr (SArr _ a) (SArr _ b) = SVal KBool $ Right $ cache c
  where c st = do ai <- uncacheAI a st
                  bi <- uncacheAI b st
                  newExpr st KBool (SBVApp (ArrEq ai bi) [])

---------------------------------------------------------------------------------
-- * Cached values
---------------------------------------------------------------------------------

-- | We implement a peculiar caching mechanism, applicable to the use case in
-- implementation of SBV's.  Whenever we do a state based computation, we do
-- not want to keep on evaluating it in the then-current state. That will
-- produce essentially a semantically equivalent value. Thus, we want to run
-- it only once, and reuse that result, capturing the sharing at the Haskell
-- level. This is similar to the "type-safe observable sharing" work, but also
-- takes into the account of how symbolic simulation executes.
--
-- See Andy Gill's type-safe obervable sharing trick for the inspiration behind
-- this technique: <http://ittc.ku.edu/~andygill/paper.php?label=DSLExtract09>
--
-- Note that this is *not* a general memo utility!
newtype Cached a = Cached (State -> IO a)

-- | Cache a state-based computation
cache :: (State -> IO a) -> Cached a
cache = Cached

-- | Uncache a previously cached computation
uncache :: Cached SW -> State -> IO SW
uncache = uncacheGen rSWCache

-- | An array index is simple an int value
type ArrayIndex = Int

-- | Uncache, retrieving array indexes
uncacheAI :: Cached ArrayIndex -> State -> IO ArrayIndex
uncacheAI = uncacheGen rAICache

-- | Generic uncaching. Note that this is entirely safe, since we do it in the IO monad.
uncacheGen :: (State -> IORef (Cache a)) -> Cached a -> State -> IO a
uncacheGen getCache (Cached f) st = do
        let rCache = getCache st
        stored <- readIORef rCache
        sn <- f `seq` makeStableName f
        let h = hashStableName sn
        case maybe Nothing (sn `lookup`) (h `IMap.lookup` stored) of
          Just r  -> return r
          Nothing -> do r <- f st
                        r `seq` modifyIORef rCache (IMap.insertWith (++) h [(sn, r)])
                        return r

-- | Representation of SMTLib Program versions, currently we only know of versions 1 and 2.
-- (NB. Eventually, we should just drop SMTLib1.)
data SMTLibVersion = SMTLib1
                   | SMTLib2
                   deriving Eq

-- | Representation of an SMT-Lib program. In between pre and post goes the refuted models
data SMTLibPgm = SMTLibPgm SMTLibVersion  ( [(String, SW)]          -- alias table
                                          , [String]                -- pre: declarations.
                                          , [String])               -- post: formula
instance NFData SMTLibVersion where rnf a = seq a ()
instance NFData SMTLibPgm     where rnf a = seq a ()

instance Show SMTLibPgm where
  show (SMTLibPgm _ (_, pre, post)) = intercalate "\n" $ pre ++ post

-- Other Technicalities..
instance NFData CW where
  rnf (CW x y) = x `seq` y `seq` ()

instance NFData Result where
  rnf (Result kindInfo qcInfo cgs inps consts tbls arrs uis axs pgm cstr outs)
        = rnf kindInfo `seq` rnf qcInfo `seq` rnf cgs  `seq` rnf inps
                       `seq` rnf consts `seq` rnf tbls `seq` rnf arrs
                       `seq` rnf uis    `seq` rnf axs  `seq` rnf pgm
                       `seq` rnf cstr   `seq` rnf outs
instance NFData Kind          where rnf a = seq a ()
instance NFData ArrayContext  where rnf a = seq a ()
instance NFData SW            where rnf a = seq a ()
instance NFData SBVExpr       where rnf a = seq a ()
instance NFData Quantifier    where rnf a = seq a ()
instance NFData SBVType       where rnf a = seq a ()
instance NFData UnintKind     where rnf a = seq a ()
instance NFData a => NFData (Cached a) where
  rnf (Cached f) = f `seq` ()
instance NFData SVal where
  rnf (SVal x y) = rnf x `seq` rnf y `seq` ()
instance NFData SBVPgm        where rnf a = seq a ()


instance NFData SMTResult where
  rnf (Unsatisfiable _)   = ()
  rnf (Satisfiable _ xs)  = rnf xs `seq` ()
  rnf (Unknown _ xs)      = rnf xs `seq` ()
  rnf (ProofError _ xs)   = rnf xs `seq` ()
  rnf (TimeOut _)         = ()

instance NFData SMTModel where
  rnf (SMTModel assocs unints uarrs) = rnf assocs `seq` rnf unints `seq` rnf uarrs `seq` ()

instance NFData SMTScript where
  rnf (SMTScript b m) = rnf b `seq` rnf m `seq` ()

-- | SMT-Lib logics. If left unspecified SBV will pick the logic based on what it determines is needed. However, the
-- user can override this choice using the 'useLogic' parameter to the configuration. This is especially handy if
-- one is experimenting with custom logics that might be supported on new solvers. See <http://smtlib.cs.uiowa.edu/logics.shtml>
-- for the official list.
data SMTLibLogic
  = AUFLIA    -- ^ Formulas over the theory of linear integer arithmetic and arrays extended with free sort and function symbols but restricted to arrays with integer indices and values
  | AUFLIRA   -- ^ Linear formulas with free sort and function symbols over one- and two-dimentional arrays of integer index and real value
  | AUFNIRA   -- ^ Formulas with free function and predicate symbols over a theory of arrays of arrays of integer index and real value
  | LRA       -- ^ Linear formulas in linear real arithmetic
  | QF_ABV    -- ^ Quantifier-free formulas over the theory of bitvectors and bitvector arrays
  | QF_AUFBV  -- ^ Quantifier-free formulas over the theory of bitvectors and bitvector arrays extended with free sort and function symbols
  | QF_AUFLIA -- ^ Quantifier-free linear formulas over the theory of integer arrays extended with free sort and function symbols
  | QF_AX     -- ^ Quantifier-free formulas over the theory of arrays with extensionality
  | QF_BV     -- ^ Quantifier-free formulas over the theory of fixed-size bitvectors
  | QF_IDL    -- ^ Difference Logic over the integers. Boolean combinations of inequations of the form x - y < b where x and y are integer variables and b is an integer constant
  | QF_LIA    -- ^ Unquantified linear integer arithmetic. In essence, Boolean combinations of inequations between linear polynomials over integer variables
  | QF_LRA    -- ^ Unquantified linear real arithmetic. In essence, Boolean combinations of inequations between linear polynomials over real variables.
  | QF_NIA    -- ^ Quantifier-free integer arithmetic.
  | QF_NRA    -- ^ Quantifier-free real arithmetic.
  | QF_RDL    -- ^ Difference Logic over the reals. In essence, Boolean combinations of inequations of the form x - y < b where x and y are real variables and b is a rational constant.
  | QF_UF     -- ^ Unquantified formulas built over a signature of uninterpreted (i.e., free) sort and function symbols.
  | QF_UFBV   -- ^ Unquantified formulas over bitvectors with uninterpreted sort function and symbols.
  | QF_UFIDL  -- ^ Difference Logic over the integers (in essence) but with uninterpreted sort and function symbols.
  | QF_UFLIA  -- ^ Unquantified linear integer arithmetic with uninterpreted sort and function symbols.
  | QF_UFLRA  -- ^ Unquantified linear real arithmetic with uninterpreted sort and function symbols.
  | QF_UFNRA  -- ^ Unquantified non-linear real arithmetic with uninterpreted sort and function symbols.
  | UFLRA     -- ^ Linear real arithmetic with uninterpreted sort and function symbols.
  | UFNIA     -- ^ Non-linear integer arithmetic with uninterpreted sort and function symbols.
  | QF_FPBV   -- ^ Quantifier-free formulas over the theory of floating point numbers, arrays, and bit-vectors
  | QF_FP     -- ^ Quantifier-free formulas over the theory of floating point numbers
  deriving Show

-- | Chosen logic for the solver
data Logic = PredefinedLogic SMTLibLogic  -- ^ Use one of the logics as defined by the standard
           | CustomLogic     String       -- ^ Use this name for the logic

instance Show Logic where
  show (PredefinedLogic l) = show l
  show (CustomLogic     s) = s

-- | Translation tricks needed for specific capabilities afforded by each solver
data SolverCapabilities = SolverCapabilities {
         capSolverName              :: String       -- ^ Name of the solver
       , mbDefaultLogic             :: Maybe String -- ^ set-logic string to use in case not automatically determined (if any)
       , supportsMacros             :: Bool         -- ^ Does the solver understand SMT-Lib2 macros?
       , supportsProduceModels      :: Bool         -- ^ Does the solver understand produce-models option setting
       , supportsQuantifiers        :: Bool         -- ^ Does the solver understand SMT-Lib2 style quantifiers?
       , supportsUninterpretedSorts :: Bool         -- ^ Does the solver understand SMT-Lib2 style uninterpreted-sorts
       , supportsUnboundedInts      :: Bool         -- ^ Does the solver support unbounded integers?
       , supportsReals              :: Bool         -- ^ Does the solver support reals?
       , supportsFloats             :: Bool         -- ^ Does the solver support single-precision floating point numbers?
       , supportsDoubles            :: Bool         -- ^ Does the solver support double-precision floating point numbers?
       }

-- | Rounding mode to be used for the IEEE floating-point operations.
-- Note that Haskell's default is 'RoundNearestTiesToEven'. If you use
-- a different rounding mode, then the counter-examples you get may not
-- match what you observe in Haskell.
data RoundingMode = RoundNearestTiesToEven  -- ^ Round to nearest representable floating point value.
                                            -- If precisely at half-way, pick the even number.
                                            -- (In this context, /even/ means the lowest-order bit is zero.)
                  | RoundNearestTiesToAway  -- ^ Round to nearest representable floating point value.
                                            -- If precisely at half-way, pick the number further away from 0.
                                            -- (That is, for positive values, pick the greater; for negative values, pick the smaller.)
                  | RoundTowardPositive     -- ^ Round towards positive infinity. (Also known as rounding-up or ceiling.)
                  | RoundTowardNegative     -- ^ Round towards negative infinity. (Also known as rounding-down or floor.)
                  | RoundTowardZero         -- ^ Round towards zero. (Also known as truncation.)
                  deriving (Eq, Ord, G.Data, T.Typeable, Read, Show, Bounded, Enum)

-- | Solver configuration. See also 'z3', 'yices', 'cvc4', 'boolector', 'mathSAT', etc. which are instantiations of this type for those solvers, with
-- reasonable defaults. In particular, custom configuration can be created by varying those values. (Such as @z3{verbose=True}@.)
--
-- Most fields are self explanatory. The notion of precision for printing algebraic reals stems from the fact that such values does
-- not necessarily have finite decimal representations, and hence we have to stop printing at some depth. It is important to
-- emphasize that such values always have infinite precision internally. The issue is merely with how we print such an infinite
-- precision value on the screen. The field 'printRealPrec' controls the printing precision, by specifying the number of digits after
-- the decimal point. The default value is 16, but it can be set to any positive integer.
--
-- When printing, SBV will add the suffix @...@ at the and of a real-value, if the given bound is not sufficient to represent the real-value
-- exactly. Otherwise, the number will be written out in standard decimal notation. Note that SBV will always print the whole value if it
-- is precise (i.e., if it fits in a finite number of digits), regardless of the precision limit. The limit only applies if the representation
-- of the real value is not finite, i.e., if it is not rational.
data SMTConfig = SMTConfig {
         verbose        :: Bool             -- ^ Debug mode
       , timing         :: Bool             -- ^ Print timing information on how long different phases took (construction, solving, etc.)
       , sBranchTimeOut :: Maybe Int        -- ^ How much time to give to the solver for each call of 'sBranch' check. (In seconds. Default: No limit.)
       , timeOut        :: Maybe Int        -- ^ How much time to give to the solver. (In seconds. Default: No limit.)
       , printBase      :: Int              -- ^ Print integral literals in this base (2, 8, 10, and 16 are supported.)
       , printRealPrec  :: Int              -- ^ Print algebraic real values with this precision. (SReal, default: 16)
       , solverTweaks   :: [String]         -- ^ Additional lines of script to give to the solver (user specified)
       , satCmd         :: String           -- ^ Usually "(check-sat)". However, users might tweak it based on solver characteristics.
       , smtFile        :: Maybe FilePath   -- ^ If Just, the generated SMT script will be put in this file (for debugging purposes mostly)
       , useSMTLib2     :: Bool             -- ^ If True, we'll treat the solver as using SMTLib2 input format. Otherwise, SMTLib1
       , solver         :: SMTSolver        -- ^ The actual SMT solver.
       , roundingMode   :: RoundingMode     -- ^ Rounding mode to use for floating-point conversions
       , useLogic       :: Maybe Logic      -- ^ If Nothing, pick automatically. Otherwise, either use the given one, or use the custom string.
       }

instance Show SMTConfig where
  show = show . solver

-- | A model, as returned by a solver
data SMTModel = SMTModel {
        modelAssocs    :: [(String, CW)]        -- ^ Mapping of symbolic values to constants.
     ,  modelArrays    :: [(String, [String])]  -- ^ Arrays, very crude; only works with Yices.
     ,  modelUninterps :: [(String, [String])]  -- ^ Uninterpreted funcs; very crude; only works with Yices.
     }
     deriving Show

-- | The result of an SMT solver call. Each constructor is tagged with
-- the 'SMTConfig' that created it so that further tools can inspect it
-- and build layers of results, if needed. For ordinary uses of the library,
-- this type should not be needed, instead use the accessor functions on
-- it. (Custom Show instances and model extractors.)
data SMTResult = Unsatisfiable SMTConfig            -- ^ Unsatisfiable
               | Satisfiable   SMTConfig SMTModel   -- ^ Satisfiable with model
               | Unknown       SMTConfig SMTModel   -- ^ Prover returned unknown, with a potential (possibly bogus) model
               | ProofError    SMTConfig [String]   -- ^ Prover errored out
               | TimeOut       SMTConfig            -- ^ Computation timed out (see the 'timeout' combinator)

-- | A script, to be passed to the solver.
data SMTScript = SMTScript {
          scriptBody  :: String        -- ^ Initial feed
        , scriptModel :: Maybe String  -- ^ Optional continuation script, if the result is sat
        }

-- | An SMT engine
type SMTEngine = SMTConfig -> Bool -> [(Quantifier, NamedSymVar)] -> [(String, UnintKind)] -> [Either SW (SW, [SW])] -> String -> IO SMTResult

-- | Solvers that SBV is aware of
data Solver = Z3
            | Yices
            | Boolector
            | CVC4
            | MathSAT
            | ABC
            deriving (Show, Enum, Bounded)

-- | An SMT solver
data SMTSolver = SMTSolver {
         name           :: Solver               -- ^ The solver in use
       , executable     :: String               -- ^ The path to its executable
       , options        :: [String]             -- ^ Options to provide to the solver
       , engine         :: SMTEngine            -- ^ The solver engine, responsible for interpreting solver output
       , xformExitCode  :: ExitCode -> ExitCode -- ^ Should we re-interpret exit codes. Most solvers behave rationally, i.e., id will do. Some (like CVC4) don't.
       , capabilities   :: SolverCapabilities   -- ^ Various capabilities of the solver
       }

instance Show SMTSolver where
   show = show . name
