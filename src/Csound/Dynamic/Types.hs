-- | Main types
{-# Language DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module Csound.Dynamic.Types(
    E, RatedExp(..), isEmptyExp, RatedVar, ratedVar, ratedVarRate, ratedVarId, Exp, toPrimOr, PrimOr(..), MainExp(..), Name, 
    InstrId(..), intInstrId, ratioInstrId, stringInstrId,
    VarType(..), Var(..), Info(..), OpcFixity(..), Rate(..), 
    Signature(..), isInfix, isPrefix,    
    Prim(..), Gen(..),  
    Inline(..), InlineExp(..), PreInline(..),
    BoolExp, CondInfo, CondOp(..), isTrue, isFalse,    
    NumExp, NumOp(..), Note,    
    -- Dependency tracking
    Dep(..), runDep, 
    -- Csd-file
    Csd(..), Flags, Orc(..), Sco(..), Instr(..),
    module Csound.Dynamic.EventList
) where

import Control.Applicative
import Control.Monad.Trans.State.Strict
import Control.Monad(ap)
import Data.Traversable
import Data.Foldable hiding (concat)

import Data.Map(Map)
import Data.Maybe(isNothing)
import qualified Data.IntMap as IM
import Data.Fix

import qualified Csound.Dynamic.Tfm.DeduceTypes as R(Var(..)) 
import Csound.Dynamic.EventList
import Csound.Dynamic.Flags

type Name = String

-- | An instrument identifier
data InstrId 
    = InstrId 
    { instrIdFrac :: Maybe Int
    , instrIdCeil :: Int }
    | InstrLabel String 
    deriving (Show, Eq, Ord)
    
-- | Constructs an instrument id with the integer.
intInstrId :: Int -> InstrId
intInstrId n = InstrId Nothing n

-- | Constructs an instrument id with fractional part.
ratioInstrId :: Int -> Int -> InstrId
ratioInstrId beforeDot afterDot = InstrId (Just $ afterDot) beforeDot

-- | Constructs an instrument id with the string label.
stringInstrId :: String -> InstrId
stringInstrId = InstrLabel

-- | The inner representation of csound expressions.
type E = Fix RatedExp

data RatedExp a = RatedExp 
    { ratedExpRate      :: Maybe Rate       
        -- ^ Rate (can be undefined or Nothing, 
        -- it means that rate should be deduced automatically from the context)
    , ratedExpDepends   :: Maybe a          
        -- ^ Dependency (it is used for expressions with side effects,
        -- value contains the privious statement)
    , ratedExpExp       :: Exp a    
        -- ^ Main expression
    } deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

-- | RatedVar is for pretty printing of the wiring ports.
type RatedVar = R.Var Rate

-- | Makes an rated variable.
ratedVar :: Rate -> Int -> RatedVar
ratedVar     = flip R.Var

-- | Querries a rate.
ratedVarRate :: RatedVar -> Rate
ratedVarRate = R.varType

-- | Querries an integral identifier.
ratedVarId :: RatedVar -> Int
ratedVarId   = R.varId

-- | It's a primitive value or something else. It's used for inlining
-- of the constants (primitive values).
newtype PrimOr a = PrimOr { unPrimOr :: Either Prim a }
    deriving (Show, Eq, Ord, Functor)

-- | Constructs PrimOr values from the expressions. It does inlining in
-- case of primitive values.
toPrimOr :: E -> PrimOr E
toPrimOr a = PrimOr $ case ratedExpExp $ unFix a of
    ExpPrim (PString _) -> Right a
    ExpPrim p -> Left p
    _         -> Right a

-- Expressions with inlining.
type Exp a = MainExp (PrimOr a)

-- Csound expressions
data MainExp a     
    = EmptyExp
    -- | Primitives
    | ExpPrim Prim
    -- | Application of the opcode: we have opcode information (Info) and the arguments [a] 
    | Tfm Info [a]
    -- | Rate conversion
    | ConvertRate Rate Rate a
    -- | Selects a cell from the tuple, here argument is always a tuple (result of opcode that returns several outputs)
    | Select Rate Int a
    -- | if-then-else
    | If (CondInfo a) a a    
    -- | Boolean expressions (rendered in infix notation in the Csound)
    | ExpBool (BoolExp a)
    -- | Numerical expressions (rendered in infix notation in the Csound)
    | ExpNum (NumExp a)
    -- | Reading/writing a named variable
    | InitVar Var a
    | ReadVar Var
    | WriteVar Var a    
    -- | Imperative If-then-else
    | IfBegin (CondInfo a)
    | ElseIfBegin (CondInfo a)
    | ElseBegin
    | IfEnd
    -- | Verbatim stmt
    | Verbatim String
    deriving (Show, Eq, Ord, Functor, Foldable, Traversable)  

isEmptyExp :: E -> Bool
isEmptyExp e = isNothing (ratedExpDepends re) && (ratedExpExp re == EmptyExp)
    where re = unFix e

-- Named variable
data Var 
    = Var
        { varType :: VarType    -- global / local
        , varRate :: Rate
        , varName :: Name } 
    | VarVerbatim 
        { varRate :: Rate
        , varName :: Name        
        } deriving (Show, Eq, Ord)       
        
-- Variables can be global (then we have to prefix them with `g` in the rendering) or local.
data VarType = LocalVar | GlobalVar
    deriving (Show, Eq, Ord)

-- Opcode information.
data Info = Info 
    -- Opcode name
    { infoName          :: Name     
    -- Opcode type signature
    , infoSignature     :: Signature
    -- Opcode can be infix or prefix
    , infoOpcFixity     :: OpcFixity
    } deriving (Show, Eq, Ord)           
  
isPrefix, isInfix :: Info -> Bool

isPrefix = (Prefix ==) . infoOpcFixity
isInfix  = (Infix  ==) . infoOpcFixity
 
-- Opcode fixity
data OpcFixity = Prefix | Infix | Opcode
    deriving (Show, Eq, Ord)

-- | The Csound rates.
data Rate   -- rate:
    ----------------------------
    = Xr    -- audio or control (and I use it for opcodes that produce no output, ie procedures)
    | Ar    -- audio 
    | Kr    -- control 
    | Ir    -- init (constants)    
    | Sr    -- strings
    | Fr    -- spectrum (for pvs opcodes)
    | Wr    -- special spectrum 
    | Tvar  -- I don't understand what it is (fix me) used with Fr
    deriving (Show, Eq, Ord, Enum, Bounded)
    
-- Opcode type signature. Opcodes can produce single output (SingleRate) or multiple outputs (MultiRate).
-- In Csound opcodes are often have several signatures. That is one opcode name can produce signals of the 
-- different rate (it depends on the type of the outputs). Here we assume (to make things easier) that
-- opcodes that MultiRate-opcodes can produce only the arguments of the same type. 
data Signature 
    -- For SingleRate-opcodes type signature is the Map from output rate to the rate of the arguments.
    -- With it we can deduce the type of the argument from the type of the output.
    = SingleRate (Map Rate [Rate]) 
    -- For MultiRate-opcodes Map degenerates to the singleton. We have only one link. 
    -- It contains rates for outputs and inputs.
    | MultiRate 
        { outMultiRate :: [Rate] 
        , inMultiRate  :: [Rate] } 
    deriving (Show, Eq, Ord)

-- Primitive values
data Prim 
    -- instrument p-arguments
    = P Int 
    | PString Int       -- >> p-string: 
    | PrimInt Int 
    | PrimDouble Double 
    | PrimString String 
    | PrimInstrId InstrId
    deriving (Show, Eq, Ord)

-- Gen routine.
data Gen = Gen 
    { genSize    :: Int
    , genId      :: Int
    , genArgs    :: [Double]
    , genFile    :: Maybe String
    } deriving (Show, Eq, Ord)

-- Csound note
type Note = [Prim]

------------------------------------------------------------
-- types for arithmetic and boolean expressions

data Inline a b = Inline 
    { inlineExp :: InlineExp a
    , inlineEnv :: IM.IntMap b    
    } deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

-- Inlined expression. 
data InlineExp a
    = InlinePrim Int
    | InlineExp a [InlineExp a]
    deriving (Show, Eq, Ord)

-- Expression as a tree (to be inlined)
data PreInline a b = PreInline a [b]
    deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

-- booleans

type BoolExp a = PreInline CondOp a
type CondInfo a = Inline CondOp a

-- Conditional operators
data CondOp  
    = TrueOp | FalseOp | And | Or
    | Equals | NotEquals | Less | Greater | LessEquals | GreaterEquals
    deriving (Show, Eq, Ord)    

isTrue, isFalse :: CondInfo a -> Bool

isTrue  = isCondOp TrueOp
isFalse = isCondOp FalseOp

isCondOp :: CondOp -> CondInfo a -> Bool
isCondOp op = maybe False (op == ) . getCondInfoOp

getCondInfoOp :: CondInfo a -> Maybe CondOp
getCondInfoOp x = case inlineExp x of
    InlineExp op _ -> Just op
    _ -> Nothing

-- Numeric expressions (or Csound infix operators)

type NumExp a = PreInline NumOp a

data NumOp = Add | Sub | Neg | Mul | Div | Pow | Mod 
    deriving (Show, Eq, Ord)

-------------------------------------------------------
-- instances for cse that ghc was not able to derive for me

instance Foldable PrimOr where foldMap = foldMapDefault

instance Traversable PrimOr where
    traverse f x = case unPrimOr x of
        Left  p -> pure $ PrimOr $ Left p
        Right a -> PrimOr . Right <$> f a

------------------------------------------------------------------------------------------
-- | Dependency tracking

-- | Csound's synonym for 'IO'-monad. 'Dep' means Side Effect. 
-- You will bump into 'Dep' trying to read and write to delay lines,
-- making random signals or trying to save your audio to file. 
-- Instrument is expected to return a value of @Dep [Sig]@. 
-- So it's okay to do some side effects when playing a note.
newtype Dep a = Dep { unDep :: State (Maybe E) a }

instance Functor Dep where
    fmap f = Dep . fmap f . unDep

instance Applicative Dep where
    pure = return
    (<*>) = ap

instance Monad Dep where
    return = Dep . return
    ma >>= mf = Dep $ unDep ma >>= unDep . mf

runDep :: Dep a -> (a, Maybe E)
runDep a = runState (unDep a) Nothing

--------------------------------------------------------------
-- csound file

data Csd = Csd
    { csdFlags  :: Flags
    , csdOrc    :: Orc
    , csdSco    :: Sco
    } 

data Orc = Orc
    { orcHead           :: Dep ()
    , orcInstruments    :: [Instr]
    }

data Instr = Instr
    { instrName :: InstrId
    , instrBody :: Dep ()
    }

data Sco = Sco 
    { scoTotalDur   :: Maybe Double
    , scoGens       :: [(Int, Gen)]
    , scoNotes      :: [(InstrId, [CsdEvent Note])]  }

--------------------------------------------------------------
-- comments
-- 
-- p-string 
--
--    separate p-param for strings (we need it to read strings from global table) 
--    Csound doesn't permits us to use more than four string params so we need to
--    keep strings in the global table and use `strget` to read them

