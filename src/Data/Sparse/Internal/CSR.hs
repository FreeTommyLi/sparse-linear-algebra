module Data.Sparse.Internal.CSR where

import Control.Applicative
import Control.Monad.Primitive
import Control.Monad.ST

import qualified Data.Foldable as F -- (foldl')
-- import Data.List (group, groupBy)

import qualified Data.Vector as V 
-- import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Algorithms.Merge as VA (sortBy)
-- import qualified Data.Vector.Generic as VG (convert)

import Data.Complex

import Data.Sparse.Utils
import Data.Sparse.Types

import Numeric.LinearAlgebra.Class


{-| Compressed Row Storage specification :

   http://netlib.org/utk/people/JackDongarra/etemplates/node373.html

   The compressed row storage (CRS) format puts the subsequent nonzeros of the matrix
   rows in contiguous memory locations. Assuming we have a nonsymmetric sparse matrix
   $A$, we create three vectors: one for floating point numbers (val) and the other
   two for integers (col_ind, row_ptr).

   The val vector stores the values of the nonzero elements of the matrix $A$ as
   they are traversed in a row-wise fashion.
 
   The col_ind vector stores the column indexes of the elements in the val vector,
   that is, if val(k)=a_{i,j}, then  col_ind(k)=j$.

   The row_ptr vector stores the locations in the val vector that start a row;
   that is, if  val(k)=a_{i,j}, then row_ptr(i) <= k < row_ptr(i+1)

-}

data CsrMatrix a =
  CM {
      csrNrows :: {-# UNPACK #-} !Int,
      csrNcols :: {-# UNPACK #-} !Int,
      csrNz :: {-# UNPACK #-} !Int,
      csrColIx :: V.Vector Int,
      csrRowPtr :: V.Vector Int,
      csrVal :: V.Vector a} deriving Eq

instance Functor CsrMatrix where
  fmap f (CM m n nz cc rp x) = CM m n nz cc rp (fmap f x)

instance Foldable CsrMatrix where
  foldr f z (CM _ _ _ _ _ x) = foldr f z x

instance Show a => Show (CsrMatrix a) where
  show mm@(CM m n nz cix rp x) = szs where
    szs = unwords ["CSR (",show m, "x", show n,"),",show nz, "NZ:","column indices:",show cix,", row pointers:", show rp,", data:",show x]

toCSR :: Int -> Int -> V.Vector (Int, Int, a) -> CsrMatrix a
toCSR m n ijxv = CM m n nz cix crp x where
  ijxv' = sortByRows ijxv -- merge sort over row indices ( O(log N) )
  nz = V.length ijxv'  
  (rp, cix, x) = V.unzip3 ijxv'
  crp = csrPtrVM m rp        -- scanl + replicate + takeWhile * map ( O(N) )
  sortByRows = V.modify (VA.sortBy f) where
       f a b = compare (fst3 a) (fst3 b)
  csrPtrVM nrows xs = V.scanl (+) 0 $ V.create createf where
   createf :: ST s (VM.MVector s Int)
   createf = do
     vm <- VM.new nrows
     let loop v ll i | i == nrows = return ()
                     | otherwise = do
                                     let lp = V.length $ V.takeWhile (== i) ll
                                     VM.write v i lp
                                     loop v (V.drop lp ll) (i + 1)
     loop vm xs 0
     return vm




     
-- -- | O(1) : lookup row
lookupRow :: CsrMatrix a -> IxRow -> Maybe (CsrVector a)
lookupRow cm i | null er = Nothing
               | otherwise = Just er where er = extractRow cm i

-- -- | O(N) lookup entry by index in a sparse Vector
-- lookupEntry :: V.Vector (IxCol, a) -> IxCol -> Maybe (IxCol, a)
-- lookupEntry cr j = F.find (== j) (cvIx cr)  >>= \j' -> V

-- -- | O(N) : lookup entry by (row, column) indices. Returns Nothing if the entry is not present.
-- lookupCSR :: CsrMatrix a -> (IxRow, IxCol) -> Maybe a
-- lookupCSR csr (i,j) = lookupRow csr i >>= \c -> snd <$> lookupEntry c j

-- | O(1) : extract a row from the CSR matrix. Returns an empty Vector if the row is not present.
extractRow :: CsrMatrix a -> IxRow -> CsrVector a
extractRow (CM m n _ cc rp x) irow = CV n ixs vals where
  imin = rp V.! irow
  imax = (rp V.! (irow + 1)) - 1
  ixs = V.slice imin imax cc -- V.drop imin $ V.take (imax + 1) cv
  vals = V.slice imin imax x

extractRow' (CM m n _ cc rp x) irow = (imin, imax, ixs, vals)where
  imin = rp V.! irow
  imax = (rp V.! (irow + 1)) - 1
  ixs = V.slice imin imax cc -- V.drop imin $ V.take (imax + 1) cv
  vals = V.slice imin imax x



-- | Rebuilds the (row, column, entry) Vector from the CSR representation. Not optimized for efficiency.
fromCSR :: CsrMatrix a -> V.Vector (Int, Int, a)
fromCSR mc = mconcat $ map (\i -> withRowIx (extractRow mc i) i) [0 .. csrNrows mc - 1] where
  withRowIx (CV n icol_ v_) i = V.zip3 (V.replicate n i) icol_ v_


-- NOT OPTIMIZED : 
transposeCSR m1@(CM m n _ _ _ _) = toCSR n m $ V.zip3 jj ii xx where
  (ii, jj, xx) = V.unzip3 $ fromCSR m1






-- * Sparse vector

data CsrVector a = CV { cvDim :: {-# UNPACK #-} !Int,
                        cvIx :: V.Vector Int,
                        cvVal :: V.Vector a } deriving Eq

instance Show a => Show (CsrVector a) where
  show (CV n ix v) = unwords ["CV (",show n,"),",show nz,"NZ:",show v]
    where nz = V.length ix

instance Functor CsrVector where
  fmap f (CV n ix v) = CV n ix (fmap f v)

instance Foldable CsrVector where
  foldr f z (CV _ _ v) = foldr f z v

instance Traversable CsrVector where
  traverse f (CV n ix v) = CV n ix <$> traverse f v

-- ** Construction 

fromDenseV :: V.Vector a -> CsrVector a
fromDenseV xs = CV n (V.enumFromTo 0 (n-1)) xs where
  n = V.length xs


-- * Query

-- | O(N) Lookup an index in a CsrVector (based on `find` from Data.Foldable)
indexCV :: CsrVector a -> Int -> Maybe a
indexCV cv i =
  case F.find (== i) (cvIx cv) of
    Just i' -> Just $ (V.!) (cvVal cv) i'
    Nothing -> Nothing
      




-- | Intersection between sorted vectors, in-place updates
intersectWith ::
  Ord b => (a -> b) -> (a -> a -> c) -> V.Vector a -> V.Vector a -> V.Vector c
intersectWith f g u_ v_ = V.force $ V.create $ do
  let n = max (V.length u_) (V.length v_)
  vm <- VM.new n
  let go u_ v_ i vm | V.null u_ || V.null v_ || i == n = return (vm, i)
                    | otherwise =  do
         let (u,us) = (V.head u_, V.tail u_)
             (v,vs) = (V.head v_, V.tail v_)
         if f u == f v then do VM.write vm i (g u v)
                               go us vs (i + 1) vm
                   else if f u < f v then go us v_ i vm
                                     else go u_ vs i vm
  (vm', i') <- go u_ v_ 0 vm
  let vm'' = VM.take i' vm'
  return vm''

-- unionWith f g u_ v_ = V.force $ V.create $ do
--   let n = max (V.length u_) (V.length v_)
--   vm <- VM.new n
--   let go u_ v_ i vm | i == n = return (vm, i)
--                     | V.null u_ && V.length v_ == 1 = do
--                         VM.write vm i (g u v)
--                     | otherwise =  do
--          let (u,us) = (V.head u_, V.tail u_)
--              (v,vs) = (V.head v_, V.tail v_)
--          if f u == f v then do VM.write vm i (g u v)
--                                go us vs (i + 1) vm
--                    else if f u < f v then go us v_ i vm
--                                      else go u_ vs i vm
--   (vm', i') <- go u_ v_ 0 vm
--   let vm'' = VM.take i' vm'
--   return vm''


union u_ v_ = go u_ v_ where
  go [] [b] = [b]
  go [a] [] = [a]
  go uu@(u:us) vv@(v:vs)
    | u == v =    u : go us vs
    | u < v =     u : go us vv 
    | otherwise = v : go uu vs



-- | Binary lift over index intersection for indexed Vector
liftI2V ::
  Ord i => (a -> a -> b) -> V.Vector (i, a) -> V.Vector (i, a) -> V.Vector (i, b)
liftI2V f = intersectWith fst (\(i, x) (_, y) -> (i, f x y))






-- | Dot product, real domain
dot :: (Ord i, Num b) => V.Vector (i, b) -> V.Vector (i, b) -> b
dot a b = foldlIxV' (+) 0 $ liftI2V (*) a b 

-- | Dot product, complex domain
dotC ::
  (RealFloat a, Ord t) => V.Vector (t, Complex a) -> V.Vector (t, Complex a) -> a
dotC a b = realPart $ foldlIxV' (+) 0 $ liftI2V (\x y -> conjugate x * y) a b 



-- instance F.Foldable IxVector where
--   foldr f z v = foldr (\(_, x) a -> f a x) z (unIxVector v)

foldrIxV :: (t1 -> t2 -> t1) -> t1 -> V.Vector (t, t2) -> t1
foldrIxV f z v = V.foldr (\(_, x) a -> f a x) z v

foldlIxV' :: (t1 -> t2 -> t1) -> t1 -> V.Vector (t, t2) -> t1
foldlIxV' f z v = V.foldl' (\b (_, x) -> f b x) z v




-- * IxVector newtype
-- newtype IxVector a = IxVector { unIxVector :: V.Vector (Int, a)} deriving (Eq, Show)

-- instance Functor IxVector where
--   fmap f iv = IxVector $ fmap g (unIxVector iv) where
--     g (_i, x) = (_i, f x) -- bleh
    
-- instance Set IxVector where
--   liftI2 = liftI2IxV

-- liftI2IxV :: (a -> a -> b) -> IxVector a -> IxVector a -> IxVector b
-- liftI2IxV f a b = IxVector $ liftI2V f a' b' where
--   a' = unIxVector a
--   b' = unIxVector b

  







-- * Utilities

tail3 :: (t, t1, t2) -> (t1, t2)
tail3 (_,j,x) = (j,x)

snd3 (_,j,_) = j

fst3 :: (t, t1, t2) -> t
fst3 (i, _, _) = i





-- test data

l0 = [1,2,4,5,8]
l1 = [2,3,6]
l2 = [7]

v0,v1 :: V.Vector Int
v0 = V.fromList [0,1,2,5,6]
v1 = V.fromList [0,3,4,6]

e1, e2 :: V.Vector (Int, Double)
e1 = V.indexed $ V.fromList [1,0,0]
e2 = V.indexed $ V.fromList [0,1,0]

e1c = V.indexed $ V.fromList [1,0,0] :: V.Vector (Int, Complex Double)

m0,m1,m2,m3 :: CsrMatrix Double
m0 = toCSR 2 2 $ V.fromList [(0,0, pi), (1,0,3), (1,1,2)]
m1 = toCSR 4 4 $ V.fromList [(0,0,1), (0,2,5), (1,0,2), (1,1,3), (2,0,4), (2,3,1), (3,2,2)]
m2 = toCSR 4 4 $ V.fromList [(0,0,1), (0,2,5), (2,0,4), (2,3,1), (3,2,2)]
m3 = toCSR 4 4 $ V.fromList [(1,0,5), (1,1,8), (2,2,3), (3,1,6)]





-- playground

safe :: (a -> Bool) -> (a -> b) -> a -> Maybe b
safe q f v
  | q v = Just (f v)
  | otherwise = Nothing

vectorNonEmpty :: (V.Vector a1 -> a) -> V.Vector a1 -> Maybe a
vectorNonEmpty = safe (not . V.null)

safeHead :: V.Vector a -> Maybe a
safeHead = vectorNonEmpty V.head

safeTail :: V.Vector a -> Maybe (V.Vector a)
safeTail = vectorNonEmpty V.tail
