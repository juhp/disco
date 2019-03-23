{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE TupleSections            #-}
{-# LANGUAGE UndecidableInstances     #-}
{-# LANGUAGE ViewPatterns             #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Desugar
-- Copyright   :  disco team and contributors
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Desugaring the typechecked surface language to the untyped core
-- language.
--
-----------------------------------------------------------------------------

-- XXX TODO
--   Write linting typechecker for DTerm?

module Disco.Desugar
       ( -- * Desugaring monad
         DSM, runDSM

         -- * Programs and terms
       , desugarDefn, desugarTerm

         -- * Case expressions and patterns
       , desugarBranch, desugarGuards
       )
       where

import           Control.Monad.Cont

import           Data.Coerce
import           Unbound.Generics.LocallyNameless

import           Disco.AST.Desugared
import           Disco.AST.Surface
import           Disco.AST.Typed
import           Disco.Module
import           Disco.Syntax.Operators
import           Disco.Syntax.Prims
import           Disco.Typecheck                  (containerTy)
import           Disco.Types

------------------------------------------------------------
-- Desugaring monad
------------------------------------------------------------

-- | The desugaring monad.  Currently, needs only the ability to
--   generate fresh names (to deal with binders).
type DSM = FreshM

-- | Run a computation in the desugaring monad.
runDSM :: DSM a -> a
runDSM = flip contFreshM 1
  -- Using flip contFreshM 1 is a bit of a hack; that way we won't
  -- ever pick a name with #0 (which is what is generated by default
  -- by string2Name), hence won't conflict with any existing free
  -- variables which came from the parser.

------------------------------------------------------------
-- ATerm DSL
------------------------------------------------------------

-- A tiny DSL for building certain ATerms, which is helpful for
-- writing desugaring rules.

infixr 2 ||.
(||.) :: ATerm -> ATerm -> ATerm
(||.) = ATBin TyBool Or

infixl 6 -., +.
(-.) :: ATerm -> ATerm -> ATerm
at1 -. at2 = ATBin (getType at1) Sub at1 at2

(+.) :: ATerm -> ATerm -> ATerm
at1 +. at2 = ATBin (getType at1) Add at1 at2

infixl 7 /.
(/.) :: ATerm -> ATerm -> ATerm
at1 /. at2 = ATBin (getType at1) Div at1 at2

infix 4 <., >=.
(<.) :: ATerm -> ATerm -> ATerm
(<.) = ATBin TyBool Lt

(>=.) :: ATerm -> ATerm -> ATerm
(>=.) = ATBin TyBool Geq

(|.) :: ATerm -> ATerm -> ATerm
(|.) = ATBin TyBool Divides

infix 4 ==.
(==.) :: ATerm -> ATerm -> ATerm
(==.) = ATBin TyBool Eq

tnot :: ATerm -> ATerm
tnot = ATUn TyBool Not

(<==.) :: ATerm -> [AGuard] -> ABranch
t <==. gs = bind (toTelescope gs) t

fls :: ATerm
fls = ATBool False

tru :: ATerm
tru = ATBool True

tif :: ATerm -> AGuard
tif t = AGBool (embed t)

ctrNil :: Container -> Type -> ATerm
ctrNil ctr ty = ATContainer (containerTy ctr ty) ctr [] Nothing

ctrSingleton :: Container -> ATerm -> ATerm
ctrSingleton ctr t = ATContainer (containerTy ctr (getType t)) ctr [t] Nothing

tapp :: ATerm -> ATerm -> ATerm
tapp t1 t2 = ATApp resTy t1 t2
  where
    resTy = case getType t1 of
      (_ :->: r) -> r
      ty         -> error $ "Impossible! Got non-function type " ++ show ty ++ " in tapp"

------------------------------------------------------------
-- Definition desugaring
------------------------------------------------------------

-- | Desugar a definition (of the form @f pat1 .. patn = term@, but
--   without the name @f@ of the thing being defined) into a core
--   language term.  Each pattern desugars to an anonymous function,
--   appropriately combined with a case expression for non-variable
--   patterns.
--
--   For example, @f n (x,y) = n*x + y@ desugars to something like
--
--   @
--     n -> p -> { n*x + y  when p = (x,y)
--   @
desugarDefn :: Defn -> DSM DTerm
desugarDefn (Defn _ patTys bodyTy def) = do
  clausePairs <- mapM unbind def
  let (pats, bodies) = unzip clausePairs

  -- generate dummy variables for lambdas
  args <- zipWithM (\_ i -> fresh (string2Name ("arg" ++ show i))) (head pats) [0 :: Int ..]

  -- Create lambdas and one big case.  Recursively desugar the case to
  -- deal with arithmetic patterns.
  let branches = zipWith (mkBranch (zip args patTys)) bodies pats
  dcase <- desugarTerm $ ATCase bodyTy branches
  return $ mkLambda (foldr TyArr bodyTy patTys) (coerce args) dcase

  where
    mkBranch :: [(Name ATerm, Type)] -> ATerm -> [APattern] -> ABranch
    mkBranch xs b ps = bind (mkGuards xs ps) b

    mkGuards :: [(Name ATerm, Type)] -> [APattern] -> Telescope AGuard
    mkGuards xs ps = toTelescope $ zipWith AGPat (map (\(x,ty) -> embed (ATVar ty x)) xs) ps

------------------------------------------------------------
-- Term desugaring
------------------------------------------------------------

-- | Desugar a typechecked term.
desugarTerm :: ATerm -> DSM DTerm
desugarTerm (ATVar ty x)         = return $ DTVar ty (coerce x)
desugarTerm (ATPrim ty (PrimBOp bop)) = desugarPrimBOp ty bop
desugarTerm (ATPrim ty x)        = return $ DTPrim ty x
desugarTerm ATUnit               = return $ DTUnit
desugarTerm (ATBool b)           = return $ DTBool b
desugarTerm (ATChar c)           = return $ DTChar c
desugarTerm (ATString cs)        = desugarContainer (TyList TyC) ListContainer (map ATChar cs) Nothing
desugarTerm (ATAbs ty lam)       = do
  (args, t) <- unbind lam
  mkLambda ty (map fst args) <$> desugarTerm t

-- XXX special case for fully applied binary operators --- so far only And
desugarTerm (ATApp _ (ATApp _ (ATPrim _ (PrimBOp And)) t1) t2)
  = desugarBinApp And t1 t2

desugarTerm (ATApp ty t1 t2)     =
  DTApp ty <$> desugarTerm t1 <*> desugarTerm t2
desugarTerm (ATTup ty ts)        = desugarTuples ty ts
desugarTerm (ATInj ty s t)       =
  DTInj ty s <$> desugarTerm t
desugarTerm (ATNat ty n)         = return $ DTNat ty n
desugarTerm (ATRat r)            = return $ DTRat r

-- not t ==> {? false if t, true otherwise ?}
-- This should be turned into a standard library definition.
desugarTerm (ATUn _ Not t)       =
  desugarTerm $
    ATCase TyBool
      [ fls <==. [AGBool (embed t)]
      , tru <==. []
      ]

-- Desugar negation on TyFin to a negation on TyZ followed by a mod.
-- See the comments below re: Add and Mul on TyFin.
desugarTerm (ATUn (TyFin n) Neg t) =
  desugarTerm $ ATBin (TyFin n) Mod (ATUn TyZ Neg t) (ATNat TyN n)

desugarTerm (ATUn ty op t)       = DTUn ty op <$> desugarTerm t

-- Implies, and, or should all be turned into a standard library
-- definition.  This will require first (1) adding support for
-- modules/a standard library, including (2) the ability to define
-- infix operators.

-- (t1 implies t2) ==> (not t1 or t2)
desugarTerm (ATBin _ Impl t1 t2) = desugarTerm $ tnot t1 ||. t2

desugarTerm (ATBin _ Or t1 t2) = do
  -- t1 or t2 ==> {? true if t1, t2 otherwise ?})
  desugarTerm $
    ATCase TyBool
      [ tru <==. [tif t1]
      , t2  <==. []
      ]
desugarTerm (ATBin ty Sub t1 t2)  = desugarTerm $ ATBin ty Add t1 (ATUn ty Neg t2)
desugarTerm (ATBin ty SSub t1 t2) = desugarTerm $
  -- t1 -. t2 ==> {? 0 if t1 < t2, t1 - t2 otherwise ?}
  ATCase ty
    [ ATNat ty 0         <==. [tif (t1 <. t2)]
    , ATBin ty Sub t1 t2 <==. []
      -- NOTE, the above is slightly bogus since the whole point of SSub is
      -- because we can't subtract naturals.  However, this will
      -- immediately desugar to a DTerm.  When we write a linting
      -- typechecker for DTerms we should allow subtraction on TyN!
    ]
desugarTerm (ATBin ty IDiv t1 t2) = desugarTerm $ ATUn ty Floor (ATBin (getType t1) Div t1 t2)
desugarTerm (ATBin _ Neq t1 t2)   = desugarTerm $ tnot (t1 ==. t2)
desugarTerm (ATBin _ Gt  t1 t2)   = desugarTerm $ t2 <. t1
desugarTerm (ATBin _ Leq t1 t2)   = desugarTerm $ tnot (t2 <. t1)
desugarTerm (ATBin _ Geq t1 t2)   = desugarTerm $ tnot (t1 <. t2)

-- Addition and multiplication on TyFin just desugar to the operation
-- followed by a call to mod.
desugarTerm (ATBin (TyFin n) op t1 t2)
  | op `elem` [Add, Mul]
  = desugarTerm $
      ATBin (TyFin n) Mod
        (ATBin TyN op t1 t2)
        (ATNat TyN n)
    -- Note the typing of this is a bit funny: t1 and t2 presumably
    -- have type (TyFin n), and now we are saying that applying 'op'
    -- to them results in TyN, then applying 'mod' results in a TyFin
    -- n again.  Using TyN as the intermediate result is necessary so
    -- we don't fall into an infinite desugaring loop, and intuitively
    -- makes sense because the idea is that we first do the operation
    -- as a normal operation in "natural land" and then do a mod.
    --
    -- We will have to think carefully about how the linting
    -- typechecker for DTerms should treat TyN and TyFin.  Probably
    -- something like this will work: TyFin is a subtype of TyN, and
    -- TyN can be turned into TyFin with mod.  (We don't want such
    -- typing rules in the surface disco language itself because
    -- implicit coercions from TyFin -> N don't commute with
    -- operations like addition and multiplication, e.g. 3+3 yields 1
    -- if we add them in Z5 and then coerce to Nat, but 6 if we first
    -- coerce both and then add.

-- Desugar normal binomial coefficient (n choose k) to a multinomial
-- coefficient with a singleton list, (n choose [k]).
desugarTerm (ATBin ty Choose t1 t2)
  | getType t2 == TyN = desugarTerm $ ATBin ty Choose t1 (ctrSingleton ListContainer t2)

desugarTerm (ATBin ty op t1 t2)   = DTBin ty op <$> desugarTerm t1 <*> desugarTerm t2

desugarTerm (ATTyOp ty op t)      = return $ DTTyOp ty op t

desugarTerm (ATChain _ t1 links)  = desugarTerm $ expandChain t1 links

desugarTerm (ATContainer ty c es mell) = desugarContainer ty c es mell

desugarTerm (ATContainerComp _ ctr bqt) = do
  (qs, t) <- unbind bqt
  desugarComp ctr t qs

desugarTerm (ATLet _ t) = do
  (bs, t2) <- unbind t
  desugarLet (fromTelescope bs) t2

desugarTerm (ATCase ty bs) = DTCase ty <$> mapM desugarBranch bs

------------------------------------------------------------
-- Desugaring operators
------------------------------------------------------------

-- | XXX
desugarPrimBOp :: Type -> BOp -> DSM DTerm
desugarPrimBOp ty@(ty1 :->: ty2 :->: _resTy) op = do
  x <- fresh (string2Name "arg1")
  y <- fresh (string2Name "arg2")
  body <- desugarBinApp op (ATVar ty1 x) (ATVar ty2 y)
  return $ mkLambda ty [x, y] body
desugarPrimBOp ty op = error $ "Impossible! Got type " ++ show ty ++ " in desugarPrimBOp for " ++ show op

-- | XXX
desugarBinApp :: BOp -> ATerm -> ATerm -> DSM DTerm
desugarBinApp And t1 t2 =

  -- XXX and should be turned into a standard library function
  -- t1 and t2 ==> {? t2 if t1, false otherwise ?}
  desugarTerm $
    ATCase TyBool
      [ t2  <==. [tif t1]
      , fls <==. []
      ]

------------------------------------------------------------
-- Desugaring other stuff
------------------------------------------------------------

-- | Desugar a container comprehension.  First translate it into an
--   expanded ATerm and then recursively desugar that.
desugarComp :: Container -> ATerm -> Telescope AQual -> DSM DTerm
desugarComp ctr t qs = expandComp ctr t qs >>= desugarTerm

-- | Expand a container comprehension into an equivalent ATerm.
expandComp :: Container -> ATerm -> Telescope AQual -> DSM ATerm

-- [ t | ] = [ t ]
expandComp ctr t TelEmpty = return $ ctrSingleton ctr t

-- [ t | q, qs ] = ...
expandComp ctr t (TelCons (unrebind -> (q,qs)))
  = case q of
      -- [ t | x in l, qs ] = join (map (\x -> [t | qs]) l)
      AQBind x (unembed -> lst) -> do
        tqs <- expandComp ctr t qs
        let c            = containerTy ctr
            tTy          = getType t
            xTy          = getEltTy (getType lst)
            joinTy       = c (c tTy) :->: c tTy
            mapTy        = (xTy :->: c tTy) :->: (c xTy :->: c (c tTy))
        return $ tapp (ATPrim joinTy PrimJoin) $
          tapp
            (tapp
              (ATPrim mapTy PrimMap)
              (ATAbs (xTy :->: c tTy) (bind [(x, embed xTy)] tqs))
            )
            lst

      -- [ t | g, qs ] = if g then [ t | qs ] else []
      AQGuard (unembed -> g)    -> do
        tqs <- expandComp ctr t qs
        return $ ATCase (containerTy ctr (getType t))
          [ tqs                    <==. [tif g]
          , ctrNil ctr (getType t) <==. []
          ]

-- | Desugar a let into applications of a chain of nested lambdas.
--   /e.g./
--
--     @let x = s, y = t in q@
--
--   desugars to
--
--     @(\x. (\y. q) t) s@
desugarLet :: [ABinding] -> ATerm -> DSM DTerm
desugarLet [] t = desugarTerm t
desugarLet ((ABinding _ x (unembed -> t1)) : ls) t =
  DTApp (getType t)
    <$> (DTLam (getType t1 :->: getType t)
          <$> (bind (coerce x) <$> desugarLet ls t)
        )
    <*> desugarTerm t1

-- | Desugar a lambda from a list of argument names and types and the
--   desugared @DTerm@ expression for its body. It will be desugared
--   to a chain of one-argument lambdas. /e.g./
--
--     @\x y z. q@
--
--   desugars to
--
--     @\x. \y. \z. q@
mkLambda :: Type -> [Name ATerm] -> DTerm -> DTerm
mkLambda funty args c = go funty args
  where
    go _ []                    = c
    go ty@(_ :->: ty2) (x:xs) = DTLam ty (bind (coerce x) (go ty2 xs))

    go ty as = error $ "Impossible! mkLambda.go " ++ show ty ++ " " ++ show as

-- | Desugar a tuple to nested pairs, /e.g./ @(a,b,c,d) ==> (a,(b,(c,d)))@.a
desugarTuples :: Type -> [ATerm] -> DSM DTerm
desugarTuples _ [t]                    = desugarTerm t
desugarTuples ty@(TyPair _ ty2) (t:ts) = DTPair ty <$> desugarTerm t <*> desugarTuples ty2 ts
desugarTuples ty ats
  = error $ "Impossible! desugarTuples " ++ show ty ++ " " ++ show ats

-- | Expand a chain of comparisons into a sequence of binary
--   comparisons combined with @and@.  Note we only expand it into
--   another 'ATerm' (which will be recursively desugared), because
--   @and@ itself also gets desugared.
--
--   For example, @a < b <= c > d@ becomes @a < b and b <= c and c > d@.
expandChain :: ATerm -> [ALink] -> ATerm
expandChain _ [] = error "Can't happen! expandChain _ []"
expandChain t1 [ATLink op t2] = ATBin TyBool op t1 t2
expandChain t1 (ATLink op t2 : links) =
  tapp
    (tapp
      (ATPrim (TyBool :->: TyBool :->: TyBool) (PrimBOp And))
      (ATBin TyBool op t1 t2)
    )
    (expandChain t2 links)

-- | Desugar a branch of a case expression.
desugarBranch :: ABranch -> DSM DBranch
desugarBranch b = do
  (ags, at) <- unbind b
  dgs <- desugarGuards ags
  d   <- desugarTerm at
  return $ bind dgs d

-- | Desugar the list of guards in one branch of a case expression.
--   Pattern guards essentially remain as they are; boolean guards get
--   turned into pattern guards which match against @true@.
desugarGuards :: Telescope AGuard -> DSM (Telescope DGuard)
desugarGuards = fmap (toTelescope . concat) . mapM desugarGuard . fromTelescope
  where
    desugarGuard :: AGuard -> DSM [DGuard]

    -- A Boolean guard is desugared to a pattern-match on @true@.
    desugarGuard (AGBool (unembed -> at)) = do
      dt <- desugarTerm at
      mkMatch dt (DPBool True)

    -- 'let x = t' is desugared to 'when t is x'.
    desugarGuard (AGLet (ABinding _ x (unembed -> at))) = do
      dt <- desugarTerm at
      varMatch dt (coerce x)

    -- Desugaring 'when t is p' is the most complex case; we have to
    -- break down the pattern and match it incrementally.
    desugarGuard (AGPat (unembed -> at) p) = do
      dt <- desugarTerm at
      desugarMatch dt p

    -- Desugar a guard of the form 'when dt is p'.  An entire match is
    -- the right unit to desugar --- as opposed to, say, writing a
    -- function to desugar a pattern --- since a match may desugar to
    -- multiple matches, and on recursive calls we need to know what
    -- term/variable should be bound to the pattern.
    --
    -- A match may desugar to multiple matches for two reasons:
    --
    --   1. Nested patterns 'explode' into a 'telescope' matching one
    --   constructor at a time, for example, 'when t is (x,y,3)'
    --   becomes 'when t is (x,x0) when x0 is (y,x1) when x1 is 3'.
    --   This makes the order of matching explicit and enables lazy
    --   matching without requiring special support from the
    --   interpreter other than WHNF reduction.
    --
    --   2. Matches against arithmetic patterns desugar to a
    --   combination of matching, computation, and boolean checks.
    --   For example, 'when t is (y+1)' becomes 'when t is x0 if x0 >=
    --   1 let y = x0-1'.
    desugarMatch :: DTerm -> APattern -> DSM [DGuard]
    desugarMatch dt (APVar ty x)      = mkMatch dt (DPVar ty (coerce x))
    desugarMatch _  (APWild _)        = return []
    desugarMatch dt APUnit            = mkMatch dt DPUnit
    desugarMatch dt (APBool b)        = mkMatch dt (DPBool b)
    desugarMatch dt (APNat ty n)      = mkMatch dt (DPNat ty n)
    desugarMatch dt (APChar c)        = mkMatch dt (DPChar c)
    desugarMatch dt (APString s)      = desugarMatch dt (APList (TyList TyC) (map APChar s))
    desugarMatch dt (APTup tupTy pat) = desugarTuplePats tupTy dt pat
      where
        desugarTuplePats :: Type -> DTerm -> [APattern] -> DSM [DGuard]
        desugarTuplePats _ _  [] = error "Impossible! desugarTuplePats []"
        desugarTuplePats _ t [p] = desugarMatch t p
        desugarTuplePats ty@(TyPair _ ty2) t (p:ps) = do
          (x1,gs1) <- varForPat p
          (x2,gs2) <- case ps of
            [APVar _ px2] -> return (coerce px2, [])
            _             -> do
              x <- fresh (string2Name "x")
              (x,) <$> desugarTuplePats ty2 (DTVar ty2 x) ps
          fmap concat . sequence $
            [ mkMatch t $ DPPair ty x1 x2
            , return gs1
            , return gs2
            ]
        desugarTuplePats ty _ _
          = error $ "Impossible! desugarTuplePats with non-pair type " ++ show ty

    desugarMatch dt (APInj ty s p) = do
      (x,gs) <- varForPat p
      fmap concat . sequence $
        [ mkMatch dt $ DPInj ty s x
        , return gs
        ]

    desugarMatch dt (APCons ty p1 p2) = do
      (x1, gs1) <- varForPat p1
      (x2, gs2) <- varForPat p2
      fmap concat . sequence $
        [ mkMatch dt $ DPCons ty x1 x2, return gs1, return gs2 ]

    desugarMatch dt (APList ty []) = mkMatch dt (DPNil ty)
    desugarMatch dt (APList ty ps) =
      desugarMatch dt $ foldr (APCons ty) (APList ty []) ps

    -- when dt is (p + t) ==> when dt is x0; let v = t; [if x0 >= v]; when x0-v is p
    desugarMatch dt (APAdd ty _ p t) = arithBinMatch posRestrict (-.) dt ty p t
      where
        posRestrict plusty
          | plusty `elem` [TyN, TyF] = Just (>=.)
          | otherwise                = Nothing

    -- when dt is (p * t) ==> when dt is x0; let v = t; [if v divides x0]; when x0 / v is p
    desugarMatch dt (APMul ty _ p t) = arithBinMatch intRestrict (/.) dt ty p t
      where
        intRestrict plusty
          | plusty `elem` [TyN, TyZ] = Just (flip (|.))
          | otherwise                = Nothing

    -- when dt is (p - t) ==> when dt is x0; let v = t; when x0 + v is p
    desugarMatch dt (APSub ty p t)  = arithBinMatch (const Nothing) (+.) dt ty p t

    -- when dt is (p/q) ==> when dt is (x0/x1); when x0 is 0; when x1 is q
    desugarMatch dt (APFrac ty p q) = do
      (x1, g1) <- varForPat p
      (x2, g2) <- varForPat q
      fmap concat . sequence $
        [ mkMatch dt $ DPFrac ty x1 x2, return g1, return g2 ]

    -- when dt is (-p) ==> when dt is x0; if x0 < 0; when -x0 is p
    desugarMatch dt (APNeg ty p) = do

      -- when dt is x0
      (x0, g1) <- varFor dt

      -- if x0 < 0
      g2  <- desugarGuard $ AGBool (embed (ATVar ty (coerce x0) <. ATNat ty 0))

      -- when -x0 is p
      neg <- desugarTerm $ ATUn ty Neg (ATVar ty (coerce x0))
      g3  <- desugarMatch neg p

      return (g1 ++ g2 ++ g3)

    mkMatch :: DTerm -> DPattern -> DSM [DGuard]
    mkMatch dt dp = return [DGPat (embed dt) dp]

    varMatch :: DTerm -> Name DTerm -> DSM [DGuard]
    varMatch dt x = mkMatch dt (DPVar (getType dt) x)

    varFor :: DTerm -> DSM (Name DTerm, [DGuard])
    varFor (DTVar _ x) = return (x, [])
    varFor dt          = do
      x <- fresh (string2Name "x")
      g <- varMatch dt x
      return (x, g)

    varForPat :: APattern -> DSM (Name DTerm, [DGuard])
    varForPat (APVar _ x) = return (coerce x, [])
    varForPat p           = do
      x <- fresh (string2Name "x")
      (x,) <$> desugarMatch (DTVar (getType p) x) p

    arithBinMatch
      :: (Type -> Maybe (ATerm -> ATerm -> ATerm))
      -> (ATerm -> ATerm -> ATerm)
      -> DTerm -> Type -> APattern -> ATerm -> DSM [DGuard]
    arithBinMatch restrict inverse dt ty p t = do
      (x0, g1) <- varFor dt

      -- let v = t
      t' <- desugarTerm t
      (v, g2) <- varFor t'

      g3 <- case restrict ty of
        Nothing -> return []

        -- if x0 `cmp` v
        Just cmp ->
          desugarGuard $
            AGBool (embed (ATVar ty (coerce x0) `cmp` ATVar (getType t) (coerce v)))

      -- when x0 `inverse` v is p
      inv <- desugarTerm (ATVar ty (coerce x0) `inverse` ATVar (getType t) (coerce v))
      g4  <- desugarMatch inv p

      return (g1 ++ g2 ++ g3 ++ g4)

-- | Desugar a container literal such as @[1,2,3]@ or @{1,2,3}@.
desugarContainer :: Type -> Container -> [ATerm] -> Maybe (Ellipsis ATerm) -> DSM DTerm

-- Literal list containers desugar to nested applications of cons.
desugarContainer ty ListContainer es Nothing =
  foldr (DTBin ty Cons) (DTNil ty) <$> mapM desugarTerm es

-- A list container with an ellipsis (@[x, y, z ..]@) desugars to
-- an application of the primitive 'forever' function...
desugarContainer ty ListContainer es (Just Forever) =
  DTApp ty (DTPrim (ty :->: ty) PrimForever) <$> desugarContainer ty ListContainer es Nothing

-- ... or @[x, y, z .. e]@ desugars to an application of the primitive
-- 'until' function.
desugarContainer ty@(TyList eltTy) ListContainer es (Just (Until t)) =
  DTApp ty
    <$> (DTApp (ty :->: ty) (DTPrim (eltTy :->: ty :->: ty) PrimUntil) <$> desugarTerm t)
    <*> desugarContainer ty ListContainer es Nothing

-- Other containers with ellipses desugar to an application of the
-- appropriate container conversion function to the corresponding desugared list.
desugarContainer ty _ es mell =
  DTApp ty (DTPrim (TyList eltTy :->: ty) conv)
    <$> desugarContainer (TyList eltTy) ListContainer es mell
  where
    (conv, eltTy) = case ty of
      TyBag e -> (PrimBag, e)
      TySet e -> (PrimSet, e)
      _       -> error $ "Impossible! Non-container type " ++ show ty ++ " in desugarContainer"
