{-# LANGUAGE CPP #-}
module Main where

-- this is a simple example where lambdas only bind a single variable at a time
-- this directly corresponds to the usual de bruijn presentation

import Data.List (elemIndex)
import Data.Foldable hiding (notElem)
import Data.Maybe (fromJust)
import Data.Traversable
import Control.Monad
import Control.Applicative
import Prelude hiding (foldr,abs)
import Data.Functor.Classes
import Bound
import System.Exit

infixl 9 :@

data Exp a
  = V a
  | Exp a :@ Exp a
  | Lam (Scope () Exp a)
  | Let [Scope Int Exp a] (Scope Int Exp a)
  deriving (Eq)

#if MIN_VERSION_transformers(0,5,0) || !MIN_VERSION_transformers(0,4,0)
instance Eq1 Exp where
  liftEq g (V a) (V b) = g a b
  liftEq g (a :@ a') (b :@ b') = liftEq g a b && liftEq g a' b'
  liftEq g (Lam a) (Lam b) = liftEq g a b
  liftEq g (Let a a') (Let b b') =
      liftEq (liftEq g) a b && liftEq g a' b'
  liftEq _ _ _ = False

#else

-- these 4 classes are needed to help Eq, Ord, Show and Read pass through Scope
instance Eq1 Exp      where eq1        = (==)
#endif

-- | A smart constructor for Lam
--
-- >>> lam "y" (lam "x" (V "x" :@ V "y"))
-- Lam (Scope (Lam (Scope (V (B ()) :@ V (F (V (B ())))))))
lam :: Eq a => a -> Exp a -> Exp a
lam v b = Lam (abstract1 v b)

-- | A smart constructor for Let bindings

let_ :: Eq a => [(a,Exp a)] -> Exp a -> Exp a
let_ [] b = b
let_ bs b = Let (map (abstr . snd) bs) (abstr b)
  where abstr = abstract (`elemIndex` map fst bs)

instance Functor Exp  where fmap       = fmapDefault
instance Foldable Exp where foldMap    = foldMapDefault

instance Applicative Exp where
  pure  = V
  (<*>) = ap

instance Traversable Exp where
  traverse f (V a)      = V <$> f a
  traverse f (x :@ y)   = (:@) <$> traverse f x <*> traverse f y
  traverse f (Lam e)    = Lam <$> traverse f e
  traverse f (Let bs b) = Let <$> traverse (traverse f) bs <*> traverse f b

instance Monad Exp where
  return = V
  V a      >>= f = f a
  (x :@ y) >>= f = (x >>= f) :@ (y >>= f)
  Lam e    >>= f = Lam (e >>>= f)
  Let bs b >>= f = Let (map (>>>= f) bs) (b >>>= f)

-- these 4 classes are needed to help Eq, Ord, Show and Read pass through Scope
#if (MIN_VERSION_transformers(0,5,0)) || !(MIN_VERSION_transformers(0,4,0))
instance Eq1 Exp where
  liftEq f (V a) (V b) = f a b
  liftEq f (a :@ b) (c :@ d) = liftEq f a c && liftEq f b d
  liftEq f (Lam m) (Lam n) = liftEq f m n 
  liftEq f (Let xs b) (Let ys c) = liftEq (liftEq f) xs ys && liftEq f b c
  liftEq _ _ _ = False

instance Ord1 Exp where
  liftCompare f (V a) (V b) = f a b
  liftCompare _ V{} _ = LT
  liftCompare _ _ V{} = GT
  liftCompare f (a :@ b) (c :@ d) = liftCompare f a c `mappend` liftCompare f b d
  liftCompare _ (_ :@ _) _  `= LT
  liftCompare _ (Lam _) (_ :@ _) = GT
  liftCompare f (Lam m) (Lam n) = liftCompare f m n 
  liftCompare f (Let xs b) (Let ys c) = liftCompare (liftCompare f) xs ys `mappend` liftCompare f b c
  liftCompare _ _ (Let _ _) = LT

-- ugh...
instance Show1 Exp where
  liftShowsPrec = error "I'm too lazy to evaluate this"

instance Read1 Exp where
  liftReadsPrec = error "I'm too lazy to evaluate this"
#else
instance Eq1 Exp      where eq1 = (==)
instance Ord1 Exp     where compare1 = compare
instance Show1 Exp    where showsPrec1 = showsPrec
instance Read1 Exp    where readsPrec1 = readsPrec
#endif

-- | Compute the normal form of an expression
nf :: Exp a -> Exp a
nf e@V{}   = e
nf (Lam b) = Lam $ toScope $ nf $ fromScope b
nf (f :@ a) = case whnf f of
  Lam b -> nf (instantiate1 a b)
  f' -> nf f' :@ nf a
nf (Let bs b) = nf (inst b)
  where es = map inst bs
        inst = instantiate (es !!)

-- | Reduce a term to weak head normal form
whnf :: Exp a -> Exp a
whnf e@V{}   = e
whnf e@Lam{} = e
whnf (f :@ a) = case whnf f of
  Lam b -> whnf (instantiate1 a b)
  f'    -> f' :@ a
whnf (Let bs b) = whnf (inst b)
  where es = map inst bs
        inst = instantiate (es !!)

infixr 0 !
(!) :: Eq a => a -> Exp a -> Exp a
(!) = lam

-- | Lennart Augustsson's example from "The Lambda Calculus Cooked 4 Ways"
--
-- Modified to use recursive let, because we can.
--
-- >>> nf cooked == true
-- True

true :: Exp String
true = lam "F" $ lam "T" $ V"T"

cooked :: Exp a
cooked = fromJust $ closed $ let_
  [ ("False",  "f" ! "t" ! V"f")
  , ("True",   "f" ! "t" ! V"t")
  , ("if",     "b" ! "t" ! "f" ! V"b" :@ V"f" :@ V"t")
  , ("Zero",   "z" ! "s" ! V"z")
  , ("Succ",   "n" ! "z" ! "s" ! V"s" :@ V"n")
  , ("one",    V"Succ" :@ V"Zero")
  , ("two",    V"Succ" :@ V"one")
  , ("three",  V"Succ" :@ V"two")
  , ("isZero", "n" ! V"n" :@ V"True" :@ ("m" ! V"False"))
  , ("const",  "x" ! "y" ! V"x")
  , ("Pair",   "a" ! "b" ! "p" ! V"p" :@ V"a" :@ V"b")
  , ("fst",    "ab" ! V"ab" :@ ("a" ! "b" ! V"a"))
  , ("snd",    "ab" ! V"ab" :@ ("a" ! "b" ! V"b"))
  -- we have a lambda calculus extended with recursive bindings, so we don't need to use fix
  , ("add",    "x" ! "y" ! V"x" :@ V"y" :@ ("n" ! V"Succ" :@ (V"add" :@ V"n" :@ V"y")))
  , ("mul",    "x" ! "y" ! V"x" :@ V"Zero" :@ ("n" ! V"add" :@ V"y" :@ (V"mul" :@ V"n" :@ V"y")))
  , ("fac",    "x" ! V"x" :@ V"one" :@ ("n" ! V"mul" :@ V"x" :@ (V"fac" :@ V"n")))
  , ("eqnat",  "x" ! "y" ! V"x" :@ (V"y" :@ V"True" :@ (V"const" :@ V"False")) :@ ("x1" ! V"y" :@ V"False" :@ ("y1" ! V"eqnat" :@ V"x1" :@ V"y1")))
  , ("sumto",  "x" ! V"x" :@ V"Zero" :@ ("n" ! V"add" :@ V"x" :@ (V"sumto" :@ V"n")))
  -- but we could if we wanted to
  --  , ("fix",    "g" ! ("x" ! V"g":@ (V"x":@V"x")) :@ ("x" ! V"g":@ (V"x":@V"x")))
  --  , ("add",    V"fix" :@ ("radd" ! "x" ! "y" ! V"x" :@ V"y" :@ ("n" ! V"Succ" :@ (V"radd" :@ V"n" :@ V"y"))))
  --  , ("mul",    V"fix" :@ ("rmul" ! "x" ! "y" ! V"x" :@ V"Zero" :@ ("n" ! V"add" :@ V"y" :@ (V"rmul" :@ V"n" :@ V"y"))))
  --  , ("fac",    V"fix" :@ ("rfac" ! "x" ! V"x" :@ V"one" :@ ("n" ! V"mul" :@ V"x" :@ (V"rfac" :@ V"n"))))
  --  , ("eqnat",  V"fix" :@ ("reqnat" ! "x" ! "y" ! V"x" :@ (V"y" :@ V"True" :@ (V"const" :@ V"False")) :@ ("x1" ! V"y" :@ V"False" :@ ("y1" ! V"reqnat" :@ V"x1" :@ V"y1"))))
  --  , ("sumto",  V"fix" :@ ("rsumto" ! "x" ! V"x" :@ V"Zero" :@ ("n" ! V"add" :@ V"x" :@ (V"rsumto" :@ V"n"))))
  , ("n5",     V"add" :@ V"two" :@ V"three")
  , ("n6",     V"add" :@ V"three" :@ V"three")
  , ("n17",    V"add" :@ V"n6" :@ (V"add" :@ V"n6" :@ V"n5"))
  , ("n37",    V"Succ" :@ (V"mul" :@ V"n6" :@ V"n6"))
  , ("n703",   V"sumto" :@ V"n37")
  , ("n720",   V"fac" :@ V"n6")
  ] (V"eqnat" :@ V"n720" :@ (V"add" :@ V"n703" :@ V"n17"))

-- TODO: use a real pretty printer

prettyPrec :: [String] -> Bool -> Int -> Exp String -> ShowS
prettyPrec _      d n (V a)      = showString a
prettyPrec vs     d n (x :@ y)   = showParen d $ 
  prettyPrec vs False n x . showChar ' ' . prettyPrec vs True n y
prettyPrec (v:vs) d n (Lam b)    = showParen d $ 
  showString v . showString ". " . prettyPrec vs False n (instantiate1 (V v) b)
prettyPrec vs     d n (Let bs b) = showParen d $ 
  showString "let" .  foldr (.) id (zipWith showBinding xs bs) .
  showString " in " . indent . prettyPrec ys False n (inst b)
  where (xs,ys) = splitAt (length bs) vs
        inst = instantiate (\n -> V (xs !! n))
        indent = showString ('\n' : replicate (n + 4) ' ')
        showBinding x b = indent . showString x . showString " = " . prettyPrec ys False (n + 4) (inst b)

prettyWith :: [String] -> Exp String -> String
prettyWith vs t = prettyPrec (filter (`notElem` toList t) vs) False 0 t ""

pretty :: Exp String -> String
pretty = prettyWith $ [ [i] | i <- ['a'..'z']] ++ [i : show j | j <- [1 :: Int ..], i <- ['a'..'z'] ]

pp :: Exp String -> IO ()
pp = putStrLn . pretty

main :: IO ()
main = do
  pp cooked
  let result = nf cooked
  if result == true
    then putStrLn "Result correct."
    else do
      putStrLn "Unexpected result:"
      pp result
      exitFailure
