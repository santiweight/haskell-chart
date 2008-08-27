-----------------------------------------------------------------------------
-- |
-- Module      :  Graphics.Rendering.Chart.Axis
-- Copyright   :  (c) Tim Docker 2006
-- License     :  BSD-style (see chart/COPYRIGHT)
--
-- Code to calculate and render axes.
--
-- Note that template haskell is used to derive accessor functions
-- (see 'Data.Accessor') for each field of the following data types:
--
--     * 'AxisData'
--
--     * 'Axis'
--
--     * 'AxisStyle'
--
--     * 'LinearAxisParams'
--
-- These accessors are not shown in this API documentation.  They have
-- the same name as the field, but with the trailing underscore
-- dropped. Hence for data field f_::F in type D, they have type
--
-- @
--   f :: Data.Accessor.Accessor D F
-- @
--

{-# OPTIONS_GHC -XTemplateHaskell #-}

module Graphics.Rendering.Chart.Axis(
    Axis(..),
    AxisData(..),
    AxisT(..),
    LinearAxisParams(..),
    AxisStyle(..),
    PlotValue(..),
    LogValue(..),
    AxisFn,

    defaultAxisLineStyle, 
    defaultLinearAxis,
    defaultAxisStyle,
    autoScaledAxis,
    autoScaledAxis',
    autoScaledLogAxis,
    autoScaledLogAxis',
    timeAxis,
    autoTimeAxis,
    days, months, years,

    renderAxisGrid,
    axisOverhang,

    axisGridNone,
    axisGridAtTicks,
    axisGridAtLabels,

    axis_viewport,
    axis_ticks,
    axis_labels,
    axis_grid,

    axis_line_style,
    axis_label_style,
    axis_grid_style,
    axis_label_gap,

    axis_style,
    axis_data,

    la_labelf,
    la_nLabels,
    la_nTicks,

) where

import qualified Graphics.Rendering.Cairo as C
import Data.Time
import System.Locale (defaultTimeLocale)
import Control.Monad
import Data.List
import Data.Accessor.Template

import Graphics.Rendering.Chart.Types
import Graphics.Rendering.Chart.Renderable

-- | The basic data associated with an axis showing values of type x
data AxisData x = AxisData {

    -- | The axis_viewport_ function maps values into device
    -- cordinates.
    axis_viewport_ :: Range -> x -> Double,

    -- | The tick marks on the axis as pairs.
    -- The first element is the position on the axis
    -- (in viewport units) and the second element is the
    -- length of the tick in output coordinates.
    -- The tick starts on the axis, and positive number are drawn
    -- towards the plot area.
    axis_ticks_ :: [(x,Double)],

    -- | The labels on an axis as pairs. The first element 
    -- is the position on the axis (in viewport units) and
    -- the second is the label text string.
    axis_labels_ :: [ (x, String) ],

    -- | The positions on the axis (in viewport units) where
    -- we want to show grid lines.
    axis_grid_ :: [ x ]
}

-- | Control values for how an axis gets displayed
data AxisStyle = AxisStyle {
    axis_line_style_ :: CairoLineStyle,
    axis_label_style_ :: CairoFontStyle,
    axis_grid_style_ :: CairoLineStyle,

    -- | How far the labels are to be drawn from the axis.
    axis_label_gap_ :: Double
}


-- | A function to generate the axis data given the data values
-- to be plotted against it.
type AxisFn x = [x] -> AxisData x

data Axis x = Axis {
   axis_style_ :: AxisStyle,
   axis_data_  :: AxisFn x
   }

-- | Colletively the information we need to render an axis
data AxisT x = AxisT RectEdge AxisStyle (AxisData x)

instance ToRenderable (AxisT x) where
  toRenderable at = Renderable {
     minsize=minsizeAxis at,
     render=renderAxis at
  }

axisGridNone :: AxisData x -> AxisData x
axisGridNone ad = ad{axis_grid_=[]}

axisGridAtTicks :: AxisData x -> AxisData x
axisGridAtTicks ad = ad{axis_grid_=map fst (axis_ticks_ ad)}

axisGridAtLabels :: AxisData x -> AxisData x
axisGridAtLabels ad = ad{axis_grid_=map fst (axis_labels_ ad)}

minsizeAxis :: AxisT x -> CRender RectSize
minsizeAxis (AxisT at as ad) = do
    let labels = map snd (axis_labels_ ad)
    labelSizes <- preserveCState $ do
        setFontStyle (axis_label_style_ as)
        mapM textSize labels
    let (lw,lh) = foldl maxsz (0,0) labelSizes
    let ag = axis_label_gap_ as
    let tsize = maximum [ max 0 (-l) | (v,l) <- axis_ticks_ ad ]
    let sz = case at of
		     E_Top    -> (lw,max (addIfNZ lh ag) tsize)
		     E_Bottom -> (lw,max (addIfNZ lh ag) tsize)
		     E_Left   -> (max (addIfNZ lw ag) tsize, lh)
		     E_Right  -> (max (addIfNZ lw ag) tsize, lh)
    return sz

  where
    maxsz (w1,h1) (w2,h2) = (max w1 w2, max h1 h2)
    addIfNZ a b | a == 0 = 0
                | otherwise = a+b


-- | Calculate the amount by which the labels extend beyond
-- the ends of the axis
axisOverhang :: Ord x => AxisT x -> CRender (Double,Double)
axisOverhang (AxisT at as ad) = do
    let labels = map snd (sort (axis_labels_ ad))
    labelSizes <- preserveCState $ do
        setFontStyle (axis_label_style_ as)
        mapM textSize labels
    case labelSizes of
        [] -> return (0,0)
	ls  -> let l1 = head ls
		   l2 = last ls
		   ohangv = return (snd l1 / 2, snd l2 / 2)
		   ohangh = return (fst l1 / 2, fst l2 / 2)
		   in
		   case at of
		       E_Top -> ohangh
		       E_Bottom -> ohangh
		       E_Left -> ohangv
		       E_Right -> ohangh

renderAxis :: AxisT x -> RectSize -> CRender (PickFn ())
renderAxis at@(AxisT et as ad) sz = do
   let ls = axis_line_style_ as
   preserveCState $ do
       setLineStyle ls{line_cap_=C.LineCapSquare}
       strokeLines [Point sx sy,Point ex ey]
   preserveCState $ do
       setLineStyle ls{line_cap_=C.LineCapButt}
       mapM_ drawTick (axis_ticks_ ad)
   preserveCState $ do
       setFontStyle (axis_label_style_ as)
       mapM_ drawLabel (axis_labels_ ad)
   return (const ())
 where
   (sx,sy,ex,ey,tp,axisPoint) = axisMapping at sz

   drawTick (value,length) = 
       let t1 = axisPoint value
	   t2 = t1 `pvadd` (vscale length tp)
       in strokeLines [t1,t2]

   (hta,vta,lp) = 
       let g = axis_label_gap_ as
       in case et of
		  E_Top    -> (HTA_Centre,VTA_Bottom,(Vector 0 (-g)))
		  E_Bottom -> (HTA_Centre,VTA_Top,(Vector 0 g))
		  E_Left   -> (HTA_Right,VTA_Centre,(Vector (-g) 0))
		  E_Right  -> (HTA_Left,VTA_Centre,(Vector g 0))

   drawLabel (value,s) = do
       drawText hta vta (axisPoint value `pvadd` lp) s

axisMapping :: AxisT z -> RectSize -> (Double,Double,Double,Double,Vector,z->Point)
axisMapping (AxisT et as ad) (x2,y2) = case et of
    E_Top    -> (x1,y2,x2,y2, (Vector 0 1),    mapx (x1,x2) y2) 
    E_Bottom -> (x1,y1,x2,y1, (Vector 0 (-1)), mapx (x1,x2) y1)
    E_Left   -> (x2,y2,x2,y1, (Vector (1) 0),  mapy (y1,y2) x2)		
    E_Right  -> (x1,y2,x1,y1, (Vector (-1) 0), mapy (y1,y2) x1)
  where
    (x1,y1) = (0,0)

    mapx xr y x = Point (axis_viewport_ ad xr x) y
    mapy (yr0,yr1) x y = Point x (axis_viewport_ ad (yr1,yr0) y)

renderAxisGrid :: RectSize -> AxisT z -> CRender ()
renderAxisGrid sz@(w,h) at@(AxisT re as ad) = do
    preserveCState $ do
        setLineStyle (axis_grid_style_ as)
        mapM_ (drawGridLine re) (axis_grid_ ad)
  where
    (sx,sy,ex,ey,tp,axisPoint) = axisMapping at sz

    drawGridLine E_Top = vline
    drawGridLine E_Bottom = vline
    drawGridLine E_Left = hline
    drawGridLine E_Right = hline

    vline v = let v' = p_x (axisPoint v)
	      in strokeLines [Point v' 0,Point v' h]

    hline v = let v' = p_y (axisPoint v)
	      in strokeLines [Point 0 v',Point w v']



steps:: Double -> Range -> [Rational]
steps nSteps (min,max) = [ (fromIntegral (min' + i)) * s | i <- [0..n] ]
  where
    min' = floor (min / fromRational s)
    max' = ceiling (max / fromRational s)
    n = (max' - min')
    s = chooseStep nSteps (min,max)

chooseStep :: Double -> Range -> Rational
chooseStep nsteps (min,max) = s
  where
    mult = 10 ^^ (floor ((log (max-min) - log nsteps) / log 10))
    steps = map (mult*) [0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 2.5, 5.0, 10, 20, 25, 50]
    steps' =  sort [ (abs((max-min)/(fromRational s) - nsteps), s) | s <- steps ]
    s = snd (head steps')

makeAxis :: PlotValue x => (x -> String) -> ([x],[x],[x]) -> AxisData x
makeAxis labelf (labelvs, tickvs, gridvs) = AxisData {
    axis_viewport_=newViewport,
    axis_ticks_=newTicks,
    axis_grid_=gridvs,
    axis_labels_=newLabels
    }
  where
    newViewport = vmap (min',max')
    newTicks = [ (v,2) | v <- tickvs ] ++ [ (v,5) | v <- labelvs ] 
    newLabels = [(v,labelf v) | v <- labelvs]
    min' = minimum labelvs
    max' = maximum labelvs

data GridMode = GridNone | GridAtMajor | GridAtMinor

data LinearAxisParams = LinearAxisParams {
    -- | The function used to show the axes labels
    la_labelf_ :: Double -> String,

    -- | The target number of labels to be shown
    la_nLabels_ :: Int,

    -- | The target number of ticks to be shown
    la_nTicks_ :: Int
}


defaultLinearAxis = LinearAxisParams {
    la_labelf_ = showD,
    la_nLabels_ = 5,
    la_nTicks_ = 50
}

-- | Generate a linear axis automatically.
-- The supplied axis is used as a template, with the viewport, ticks, labels
-- and grid set appropriately for the data displayed against that axies.
-- The resulting axis will only show a grid if the template has some grid
-- values.
autoScaledAxis' :: LinearAxisParams -> AxisFn Double
autoScaledAxis' lap ps0 = makeAxis (la_labelf_ lap) (labelvs,tickvs,gridvs)
  where
    ps = filter isValidNumber ps0
    (min,max) = (minimum ps,maximum ps)
    range [] = (0,1)
    range _  | min == max = (min-0.5,min+0.5)
	     | otherwise = (min,max)
    labelvs = map fromRational $ steps (fromIntegral (la_nLabels_ lap)) r
    tickvs = map fromRational $ steps (fromIntegral (la_nTicks_ lap)) (minimum labelvs,maximum labelvs)
    gridvs = labelvs
    r = range ps

-- | Generate a linear axis automatically.
-- Same as autoScaledAxis', but with labels generated with "showD"
-- (showD is show for doubles, but with any trailing ".0" removed)
autoScaledAxis :: AxisFn Double
autoScaledAxis = autoScaledAxis' defaultLinearAxis

showD x = case reverse $ show x of
            '0':'.':r -> reverse r
            _ -> show x
    

log10 :: (Floating a) => a -> a
log10 = logBase 10

frac x | 0 <= b = (a,b)
       | otherwise = (a-1,b+1)
 where
  (a,b) = properFraction x

{- 
 Rules: Do no subdivide between powers of 10 until all powers of 10
          get a major ticks.
        Do not subdivide between powers of ten as [1,2,4,6,8,10] when
          5 gets a major ticks 
          (ie the major ticks need to be a subset of the minor tick)
-}
logTicks :: Range -> ([Rational],[Rational],[Rational])
logTicks (low,high) = (major,minor,major)
 where
  ratio = high/low
  lower a l = let (i,r) = frac (log10 a) in
            (maximum (1:(filter (\x -> log10 (fromRational x) <= r) l)))*10^^i
  upper a l = let (i,r) = properFraction (log10 a) in
            (minimum (10:(filter (\x -> r <= log10 (fromRational x)) l)))*10^^i
  inRange (a,b) l x = (lower a l <= x) && (x <= upper b l)
  powers :: (Double,Double) -> [Rational] -> [Rational]
  powers (x,y) l = [a*10^^p | p<-[(floor (log10 x))..(ceiling (log10 y))], a<-l]
  midselection r l = filter (inRange r l) (powers r l)
  major | 17.5 < log10 ratio = map (\x -> 10^^(round x)) $
                         steps (min 5 (log10 ratio)) (log10 low, log10 high)
        | 12 < log10 ratio = map (\x -> 10^^(round x)) $
                         steps ((log10 ratio)/5) (log10 low, log10 high)
        | 6 < log10 ratio = map (\x -> 10^^(round x)) $
                         steps ((log10 ratio)/2) (log10 low, log10 high)
        | 3 < log10 ratio = midselection (low,high) [1,10]
        | 20 < ratio = midselection (low,high) [1,5,10]
        | 6 < ratio = midselection (low,high) [1,2,4,6,8,10]
        | 3 < ratio = midselection (low,high) [1..10]
        | otherwise = steps 5 (low,high)
  (l',h') = (minimum major, maximum major)
  (dl',dh') = (fromRational l', fromRational h')
  ratio' = fromRational (h'/l')
  minor | 50 < log10 ratio' = map (\x -> 10^^(round x)) $
                              steps 50 (log10 $ dl', log10 $ dh')
        | 6 < log10 ratio' = filter (\x -> l'<=x && x <=h') $
                             powers (dl', dh') [1,10]
        | 3 < log10 ratio' = filter (\x -> l'<=x && x <=h') $
                             powers (dl',dh') [1,5,10]
        | 6 < ratio' = filter (\x -> l'<=x && x <=h') $ 
                       powers (dl',dh') [1..10]
        | 3 < ratio' = filter (\x -> l'<=x && x <=h') $ 
                       powers (dl',dh') [1,1.2..10]
        | otherwise = steps 50 (dl', dh')

-- | Generate a log axis automatically.
-- The supplied axis is used as a template, with the viewport, ticks, labels
-- and grid set appropriately for the data displayed against that axies.
-- The resulting axis will only show a grid if the template has some grid
-- values.
autoScaledLogAxis' :: (LogValue->String) -> AxisFn LogValue
autoScaledLogAxis' labelf ps0 = makeAxis labelf (wrap rlabelvs, wrap rtickvs, wrap rgridvs)
  where
    ps = filter (\(LogValue x) -> isValidNumber x && 0 < x) ps0
    (min, max) = (minimum ps,maximum ps)
    range [] = (3,30)
    range _  | min == max = (unLogValue min/3,unLogValue max*3)
             | otherwise = (unLogValue min,unLogValue max)
    (rlabelvs, rtickvs, rgridvs) = logTicks (range ps)
    wrap = map (LogValue . fromRational)
    unLogValue (LogValue x) = x

-- | Generate a log axis automatically.
-- Same as autoScaledLogAxis', but with labels generated with "showD"
-- (showD is show for doubles, but with any trailing ".0" removed)
autoScaledLogAxis :: AxisFn LogValue
autoScaledLogAxis = autoScaledLogAxis' (\(LogValue x) -> showD x)

----------------------------------------------------------------------

defaultAxisLineStyle = solidLine 1 black
defaultGridLineStyle = dashedLine 1 [5,5] grey8

defaultAxisStyle = AxisStyle {
    axis_line_style_ = defaultAxisLineStyle,
    axis_label_style_ = defaultFontStyle,
    axis_grid_style_ = defaultGridLineStyle,
    axis_label_gap_ = 10
}

----------------------------------------------------------------------

-- | Map a LocalTime value to a plot cordinate
doubleFromLocalTime :: LocalTime -> Double
doubleFromLocalTime lt = fromIntegral (toModifiedJulianDay (localDay lt)) 
             + fromRational (timeOfDayToDayFraction (localTimeOfDay lt))

-- | Map a plot cordinate to a LocalTime
localTimeFromDouble :: Double -> LocalTime
localTimeFromDouble v = 
  LocalTime (ModifiedJulianDay i) (dayFractionToTimeOfDay (toRational d))
 where
   (i,d) = properFraction v

-- | TimeSeq is a (potentially infinite) set of times. When passes
-- a reference time, the function returns a a pair of lists. The first
-- contains all times in the set less than the reference time in
-- decreasing order. The second contains all times in the set greater
-- than or equal to the reference time, in increasing order.
type TimeSeq = LocalTime-> ([LocalTime],[LocalTime])

coverTS tseq min max = min' ++ enumerateTS tseq min max ++ max'
  where
    min' =  if elemTS min tseq then [] else take 1 (fst (tseq min))
    max' =  if elemTS max tseq then [] else take 1 (snd (tseq max))

enumerateTS tseq min max = reverse (takeWhile (>=min) ts1)  ++ takeWhile (<=max) ts2
  where
    (ts1,ts2) = tseq min

elemTS t tseq = case tseq t of
    (_,(t0:_)) | t == t0 -> True
    _                    -> False

-- | How to display a time
type TimeLabelFn = LocalTime -> String

-- | Create an 'AxisFn' to for a time axis. The first 'TimeSeq' sets the minor ticks,
-- and the ultimate range will aligned to it's elements. The second 'TimeSeq' sets
-- the labels and grid. The 'TimeLabelFn' is used to format LocalTimes for labels.
-- The values to be plotted against this axis can be created with 'doubleFromLocalTime'
timeAxis :: TimeSeq -> TimeSeq -> TimeLabelFn -> AxisFn LocalTime
timeAxis tseq lseq labelf pts = AxisData {
    axis_viewport_=vmap(min', max'),
    axis_ticks_=[ (t,2) | t <- times] ++ [ (t,5) | t <- ltimes, visible t],
    axis_labels_=[ (t,l) | (t,l) <- labels, visible t],
    axis_grid_=[ t | t <- ltimes, visible t]
    }
  where
    (min,max) = case pts of
		[] -> (refLocalTime,refLocalTime)
		ps -> (minimum ps, maximum ps)
    refLocalTime = LocalTime (ModifiedJulianDay 0) midnight
    times = coverTS tseq min max
    ltimes = coverTS lseq min max
    min' = minimum times
    max' = maximum times
    visible t = min' <= t && t <= max'
    labels = [ (avg m1 m2, labelf m1) | (m1,m2) <- zip ltimes (tail ltimes) ]
    avg m1 m2 = localTimeFromDouble $ m1' + (m2' - m1')/2
     where
      m1' = doubleFromLocalTime m1
      m2' = doubleFromLocalTime m2

-- | A 'TimeSeq' for calendar days
days :: TimeSeq
days t = (map toTime $ iterate rev t1, map toTime $ tail (iterate fwd t1))
  where t0 = (localDay t)
        t1 = if (toTime t0) < t then t0 else (rev t0)
        rev = pred
        fwd = succ
        toTime d = LocalTime d midnight

-- | A 'TimeSeq' for calendar months
months :: TimeSeq
months t = (map toTime $ iterate rev t1, map toTime $ tail (iterate fwd t1))
  where t0 = let (y,m,d) = toGregorian $ localDay t in fromGregorian y m 1
        t1 = if toTime t0 < t then t0 else (rev t0)
        rev = addGregorianMonthsClip (-1)
        fwd = addGregorianMonthsClip 1
        toTime d = LocalTime d midnight

-- | A 'TimeSeq' for calendar years
years :: TimeSeq
years t = (map toTime $ iterate rev t1, map toTime $ tail (iterate fwd t1))
  where t0 = let (y,m,d) = toGregorian $ localDay t in y
        t1 = if toTime t0 < t then t0 else (rev t0)
        rev = pred
        fwd = succ
        toTime y = LocalTime (fromGregorian y 1 1) midnight

-- | Automatically choose a suitable time axis, based upon the time range of data.
-- The values to be plotted against this axis can be created with 'doubleFromLocalTime'
autoTimeAxis :: AxisFn LocalTime
autoTimeAxis [] = timeAxis days days (formatTime defaultTimeLocale "%d-%b")  []
autoTimeAxis pts = 
    if tdiff < 15
    then  timeAxis days days (ft "%d-%b")  pts
    else if tdiff < 90
         then timeAxis days months (ft "%b-%y") pts
         else if tdiff < 450
              then timeAxis months months (ft "%b-%y") pts
              else if tdiff < 1800
                   then timeAxis months years (ft "%Y") pts
                   else timeAxis years years (ft "%Y") pts
  where
    tdiff = diffDays (localDay t1) (localDay t0)
    t1 = maximum pts
    t0 = minimum pts
    ft = formatTime defaultTimeLocale

-----------------------------------------------------------------------------

class Ord a => PlotValue a where
    toValue :: a -> Double
    autoAxis ::AxisFn a

instance PlotValue Double where
    toValue = id
    autoAxis = autoScaledAxis

newtype LogValue = LogValue Double
                    deriving (Eq, Ord)

instance Show LogValue where
    show (LogValue x) = show x

instance PlotValue LogValue where
    toValue (LogValue x) = log x
    autoAxis = autoScaledLogAxis

instance PlotValue LocalTime where
    toValue = doubleFromLocalTime
    autoAxis = autoTimeAxis

-- | A linear mapping of points in one range to another
vmap :: PlotValue x => (x,x) -> Range -> x -> Double
vmap (v1,v2) (v3,v4) v = v3 + (toValue v - toValue v1) * (v4-v3) / (toValue v2 - toValue v1)

----------------------------------------------------------------------
-- Template haskell to derive an instance of Data.Accessor.Accessor for each field
$( deriveAccessors ''AxisData )
$( deriveAccessors ''Axis )
$( deriveAccessors ''AxisStyle )
$( deriveAccessors ''LinearAxisParams )

