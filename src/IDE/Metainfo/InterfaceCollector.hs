{-# OPTIONS_GHC -XScopedTypeVariables -XFlexibleContexts#-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Metainfo.InterfaceCollector
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
-- | This modulle extracts information from .hi files for installed packages
--
-------------------------------------------------------------------------------

module IDE.Metainfo.InterfaceCollector (
    collectInstalled
,   collectInstalled'
,   collectUninstalled
,   metadataVersion

) where


import GHC hiding(Id,Failed,Succeeded,ModuleName)
import Module hiding (PackageId,ModuleName)
import IDE.Metainfo.GHCUtils (findFittingPackages,getInstalledPackageInfos)
import MyMissing (nonEmptyLines)
import qualified Module
import TcRnMonad hiding (liftIO,MonadIO)
import qualified Maybes as M
import HscTypes hiding (liftIO)
import LoadIface
import Outputable hiding(trace)
import IfaceSyn
import FastString
import Outputable hiding(trace)
import qualified PackageConfig as DP
import Name
import PrelNames
import PackageConfig(unpackPackageId,mkPackageId)
import Maybes
import TcRnTypes
import Finder
import qualified FastString as FS
import ErrUtils
import Config(cProjectVersion)
import Distribution.PackageDescription.Parse(readPackageDescription)
import Distribution.PackageDescription.Configuration(flattenPackageDescription)
import qualified IOEnv as IOEnv (liftIO,MonadIO)
import IOEnv hiding (liftIO,MonadIO)

import Debug.Trace

import Data.Char (isSpace)
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)
import System.Directory
import Distribution.PackageDescription
import qualified Distribution.InstalledPackageInfo as IPI
import Distribution.Package hiding (PackageId)
import Distribution.Verbosity
import Distribution.ModuleName
import Distribution.Text (simpleParse,display)
import Control.Monad.Reader
import System.IO
import Data.Maybe
import System.FilePath
import System.Directory
import Data.List(zip4,nub)
import qualified Data.ByteString.Char8 as BS

import Default
import IDE.Core.State hiding (depends)
import IDE.FileUtils
--import IDE.Metainfo.Provider
import IDE.Metainfo.SourceCollector
import IDE.Metainfo.GHCUtils(inGhc)
import IDE.Metainfo.Serializable ()
import Data.Binary.Shared

metadataVersion :: Integer
metadataVersion = 5

data CollectStatistics = CollectStatistics {
    packagesTotal       ::   Int
,   packagesWithSource  ::   Int
,   modulesTotal        ::   Int
,   modulesWithSource   ::   Int
,   parseFailures       ::   Int
} deriving Show

instance Default CollectStatistics where
    getDefault          =   CollectStatistics getDefault getDefault getDefault getDefault
                                getDefault

collectInstalled :: Prefs -> Bool -> IDEAction
collectInstalled prefs b =   inGhc $ collectInstalled' prefs False cProjectVersion b

collectInstalled' :: Prefs -> Bool -> String -> Bool -> Ghc()
collectInstalled' prefs writeAscii version forceRebuild = do
    session             <- getSession
    collectorPath       <-  liftIO $ getCollectorPath version
    when forceRebuild $ liftIO $ do
        removeDirectoryRecursive collectorPath
        getCollectorPath version
        return ()
    knownPackages       <-  liftIO $ findKnownPackages collectorPath
    packageInfos        <-  getInstalledPackageInfos
    let newPackages     =   filter (\pi -> not $Set.member (fromPackageIdentifier $ IPI.package pi)
                                                        knownPackages)
                                    packageInfos
    if null newPackages then do
            sysMessage Normal "Metadata collector has nothing to do"
        else do
            liftIO $ buildSourceForPackageDB prefs
            sources             <-  liftIO $ getSourcesMap prefs
            exportedIfaceInfos  <-  mapM (\ info -> getIFaceInfos (mkPackageId $ IPI.package info)
                                                    (IPI.exposedModules info) session) newPackages
            hiddenIfaceInfos    <-  mapM (\ info -> getIFaceInfos (mkPackageId $ IPI.package info)
                                                (IPI.hiddenModules info) session) newPackages
            let extracted       =   map extractInfo $ zip4 exportedIfaceInfos
                                                        hiddenIfaceInfos
                                                        (map IPI.package newPackages)
                                                        (map depends newPackages)
            (packagesWithSource', modulesTotal', modulesWithSource', parseFailures')
                                <-  foldM (\ (pws,mt,ms,failed) pdescr   ->  do
                                            (pdescr, num)   <-  collectSources sources pdescr
                                            writeExtracted collectorPath writeAscii False pdescr
                                            let pws' = pws + if isJust (mbSourcePathPD pdescr)
                                                                then 1
                                                                else 0
                                            let mt'  = mt +  (length . exposedModulesPD) pdescr
                                            let ms'  = ms + if isJust (mbSourcePathPD pdescr)
                                                                then (length . exposedModulesPD) pdescr
                                                                else 0
                                            return (pws',mt',ms',failed + num))
                                          (0,0,0,0) extracted
            let statistic       =   CollectStatistics {
                packagesTotal       =   length extracted
            ,   packagesWithSource  =   packagesWithSource'
            ,   modulesTotal        =   modulesTotal'
            ,   modulesWithSource   =   modulesWithSource'
            ,   parseFailures       =   parseFailures'}
            liftIO $ sysMessage Normal $ show statistic
            when (modulesWithSource statistic > 0) $
                sysMessage Normal $ "failure percentage "
                    ++ show ((round (((fromIntegral   (parseFailures statistic)) :: Double) /
                               (fromIntegral   (modulesTotal statistic)) * 100.0)):: Integer)

collectUninstalled :: Bool -> String -> FilePath -> Ghc ()
collectUninstalled writeAscii version cabalPath = do
    trace ("collect Uninstalled " ++ show cabalPath) return ()
    cCabalPath          <-  liftIO $ canonicalizePath cabalPath
    pd                  <-  liftIO $ readPackageDescription normal cCabalPath
                                        >>= return . flattenPackageDescription
    let packageName     =   if hasExes pd
                                then "main"
                                else show $ package pd
    let modules         =   nub $ exeModules pd ++ libModules pd
    let basePath        =   takeDirectory cCabalPath
    let buildPath       =   if hasExes pd
                                then let exeName' = exeName (head (executables pd))
                                     in "dist" </> "build" </> exeName' </>
                                                    exeName' ++ "-tmp" </> ""
                                else "dist" </> "build" </> ""
    dflags0             <-  getSessionDynFlags
    setSessionDynFlags
        dflags0
        {  topDir      =   basePath
        ,  importPaths =   [buildPath,"dist" </> "build" </> "autogen"]
        ,  thisPackage =   if hasExes pd then mainPackageId else mkPackageId (package pd)
        ,  ghcMode     =   OneShot
        }
    dflags1         <-  getSessionDynFlags
    (dflags2,_,_)   <-  parseDynamicFlags dflags1 [(noLoc "-fglasgow-exts")]
    setSessionDynFlags dflags2
    let ghcmodules  =   map (mkModuleName . display) modules
    allIfaceInfos   <-  getIFaceInfos2 ghcmodules packageName
    deps            <-  findFittingPackages (buildDepends pd)
    let extracted   =   extractInfo (allIfaceInfos, [], package pd, deps)
    let sources     =   Map.fromList [(package pd,[cCabalPath])]
    (extractedWithSources,_)    <-  collectSources sources extracted
    collectorPath   <-  getCollectorPath version
    writeExtracted collectorPath writeAscii True extractedWithSources
    sysMessage Normal $ "\nExtracted infos for " ++ cCabalPath ++
        " size: " ++ (show . length) (exposedModulesPD extractedWithSources)

-------------------------------------------------------------------------

getIFaceInfos :: PackageId -> [Module.ModuleName] -> HscEnv -> Ghc [(ModIface, FilePath)]
getIFaceInfos pckg modules session =
    case unpackPackageId pckg of
        Nothing -> return []
        Just pid -> do
            let isBase          =   pkgName pid == (PackageName "base")
            let ifaces          =   mapM (\ mn -> findAndReadIface empty
                                                  (if isBase
                                                        then mkBaseModule_ mn
                                                        else mkModule pckg mn)
                                                  False) modules
            hscEnv              <-  getSession
            let gblEnv          =   IfGblEnv { if_rec_types = Nothing }
            maybes              <-  liftIO $ initTcRnIf  'i' hscEnv gblEnv () ifaces
            let res             =   catMaybes (map handleErr maybes)
            return res
            where
                handleErr (M.Succeeded val)   =   Just val
                handleErr (M.Failed mess)     =   Nothing

getIFaceInfos2 :: [Module.ModuleName] -> String -> Ghc [(ModIface, FilePath)]
getIFaceInfos2 modules packageName = do
    session             <-  getSession
    let ifaces          =   mapM (\ mn -> findAndReadIface2 session mn
                                            (mkModule (stringToPackageId packageName) mn)) modules
    let gblEnv          =   IfGblEnv { if_rec_types = Nothing }
    maybes              <-  liftIO $ initTcRnIf  'i' session gblEnv () ifaces
    let res             =   catMaybes (map handleErr maybes)
    return res
    where
        handleErr (M.Succeeded val)   =   Just val
        handleErr (M.Failed mess)     =   trace ("failed !!!" ++ showSDoc mess) Nothing

findAndReadIface2 :: HscEnv -> Module.ModuleName -> Module -> TcRnIf gbl lcl (MaybeErr Message (ModIface, FilePath))
findAndReadIface2 session doc mod =   do
    mb_found    <-  IOEnv.liftIO $ findHomeModule session doc
    case mb_found of
        Found loc mod   ->  do
            let file_path   =   ml_hi_file loc
            filePath        <-  IOEnv.liftIO $ canonicalizePath file_path
            read_result     <-  readIface mod filePath False
            case read_result of
	            Failed mess  ->  return (Failed (text $ "can't read iface " ++
                                                    moduleNameString doc ++ " at " ++ filePath ++ " " ++ showSDoc mess))
	            Succeeded iface
		            | mi_module iface /= mod
                        ->  return (Failed (text $ "read but not equal" ++ moduleNameString doc))
		            | otherwise
                        ->  return (Succeeded (iface, filePath))
        _               ->  return (Failed (text $ "can't locate " ++ moduleNameString doc))


-------------------------------------------------------------------------

extractInfo :: ([(ModIface, FilePath)],[(ModIface, FilePath)],PackageIdentifier,
                    [PackageIdentifier]) -> PackageDescr
extractInfo (ifacesExp,ifacesHid,pi,depends) =
    let allDescrs           =   concatMap (extractExportedDescrH pi)
                                    (map fst (ifacesHid ++ ifacesExp))
        mods                =   map (extractExportedDescrR pi allDescrs) (map fst ifacesExp)
    in PackageDescr {
        packagePD           =   pi
    ,   exposedModulesPD    =   mods
    ,   buildDependsPD      =   depends
    ,   mbSourcePathPD      =   Nothing}

extractExportedDescrH :: PackageIdentifier -> ModIface -> [Descr]
extractExportedDescrH pid iface =
    let mid                 =   (fromJust . simpleParse . moduleNameString . moduleName) (mi_module iface)
        exportedNames       =   Set.fromList
                                $ map occNameString
                                    $ concatMap availNames
                                        $ concatMap snd (mi_exports iface)
        exportedDecls       =   filter (\ ifdecl -> (occNameString $ ifName ifdecl)
                                                    `Set.member` exportedNames)
                                                            (map snd (mi_decls iface))
    in  concatMap (extractIdentifierDescr pid [mid]) exportedDecls

extractExportedDescrR :: PackageIdentifier
    -> [Descr]
    -> ModIface
    -> ModuleDescr
extractExportedDescrR pid hidden iface =
    let mid             =   (fromJust . simpleParse . moduleNameString . moduleName) (mi_module iface)
        exportedNames   =   Set.fromList
                                $map occNameString
                                    $concatMap availNames
                                        $concatMap snd (mi_exports iface)
        exportedDecls   =   filter (\ ifdecl -> (occNameString $ifName ifdecl)
                                                    `Set.member` exportedNames)
                                                            (map snd (mi_decls iface))
        ownDecls        =   concatMap (extractIdentifierDescr pid [mid]) exportedDecls
        otherDecls      =   exportedNames `Set.difference` (Set.fromList (map descrName ownDecls))
        reexported      =   map (\d -> Reexported (PM pid mid) d)
                                 $ filter (\k -> (descrName k) `Set.member` otherDecls) hidden
        inst            =   concatMap (extractInstances (PM pid mid)) (mi_insts iface)
        uses            =   Map.fromList $ map extractUsages (mi_usages iface)
    in  ModuleDescr {
                    moduleIdMD          =   PM pid mid
                ,   exportedNamesMD     =   exportedNames
                ,   mbSourcePathMD      =   Nothing
                ,   referencesMD        =   uses
                ,   idDescriptionsMD    =   ownDecls ++ inst ++ reexported}

extractIdentifierDescr :: PackageIdentifier -> [ModuleName] -> IfaceDecl
                            -> [Descr]
extractIdentifierDescr package modules decl
   = if null modules
      then []
      else
        let descr = Descr{
                    descrName'           =   unpackFS $occNameFS (ifName decl)
                ,   typeInfo'            =   BS.pack $ unlines $ nonEmptyLines $ filterExtras $ showSDocUnqual $ppr decl
                ,   descrModu'           =   PM package (last modules)
                ,   mbLocation'          =   Nothing
                ,   mbComment'           =   Nothing
                ,   details'             =   VariableDescr
                }
        in case decl of
            (IfaceId _ _ _ )
                -> [descr]
            (IfaceData name _ _ ifCons _ _ _ _)
                -> let d = case ifCons of
                            IfDataTyCon decls
                                ->  let
                                        fieldNames          =   concatMap extractFields (visibleIfConDecls ifCons)
                                        constructors'       =   extractConstructors name (visibleIfConDecls ifCons)
                                    in DataDescr{
                                            fields          =  fieldNames,
                                            constructors    =  constructors'}
                            IfNewTyCon _
                                ->  let
                                        fieldNames          =   concatMap extractFields (visibleIfConDecls ifCons)
                                        constructors'       =   extractConstructors name (visibleIfConDecls ifCons)
                                        mbField             =   case fieldNames of
                                                                    [] -> Nothing
                                                                    [fn] -> Just fn
                                                                    _ -> error $ "InterfaceCollector >> extractIdentifierDescr: "
                                                                         ++ "Newtype with more then one field"
                                        constructor         =   case constructors' of
                                                                    [c] -> c
                                                                    _ -> error $ "InterfaceCollector >> extractIdentifierDescr: "
                                                                         ++ "Newtype with not exactly one constructor"
                                    in NewtypeDescr constructor mbField
                            IfAbstractTyCon ->  DataDescr [] []
                            IfOpenDataTyCon ->  DataDescr [] []
                    in [descr{details' = d}]
            (IfaceClass context _ _ _ _ ifSigs _ )
                        ->  let
                                classOpsID          =   map extractClassOp ifSigs
                                superclasses        =   extractSuperClassNames context
                            in [descr{details' = ClassDescr{super =  superclasses,
                                        methods = classOpsID}}]
            (IfaceSyn _ _ _ _ _ )
                        ->  [descr]
            (IfaceForeign _ _)
                        ->  [descr]

extractConstructors ::   OccName -> [IfaceConDecl] -> [(Symbol,TypeInfo)]
extractConstructors name decls    =   map (\decl -> (unpackFS $occNameFS (ifConOcc decl),
                                                 (BS.pack $ filterExtras $ showSDocUnqual $
                                                    pprIfaceForAllPart (ifConUnivTvs decl ++ ifConExTvs decl)
                                                        (eq_ctxt decl ++ ifConCtxt decl) (pp_tau decl)))) decls
    where
    pp_tau decl     = case map pprParendIfaceType (ifConArgTys decl) ++ [pp_res_ty decl] of
                    		(t:ts) -> fsep (t : map (arrow <+>) ts)
                    		[]     -> panic "pp_con_taus"
    pp_res_ty decl  = ppr name <+> fsep [ppr tv | (tv,_) <- ifConUnivTvs decl]
    eq_ctxt decl    = [(IfaceEqPred (IfaceTyVar (occNameFS tv)) ty)
	                        | (tv,ty) <- ifConEqSpec decl]

extractFields ::  IfaceConDecl -> [(Symbol,TypeInfo)]
extractFields  decl    =   zip (map extractFieldNames (ifConFields decl))
                                (map extractType (ifConArgTys decl))

extractType :: IfaceType -> TypeInfo
extractType = BS.pack . filterExtras . showSDocUnqual . ppr

extractFieldNames :: OccName -> Symbol
extractFieldNames occName = unpackFS $occNameFS occName

extractClassOp :: IfaceClassOp -> (Symbol, TypeInfo)
extractClassOp (IfaceClassOp occName dm ty) = (unpackFS $occNameFS occName,
                                                BS.pack $ showSDocUnqual (ppr ty))

extractSuperClassNames :: [IfacePredType] -> [Symbol]
extractSuperClassNames l = catMaybes $ map extractSuperClassName l
    where   extractSuperClassName (IfaceClassP name _)  =
                Just (unpackFS $occNameFS $ nameOccName name)
            extractSuperClassName _                     =   Nothing

extractInstances :: PackModule -> IfaceInst -> [Descr]
extractInstances pm ifaceInst  =
    let className   =   showSDocUnqual $ ppr $ ifInstCls ifaceInst
        dataNames   =   map (\iftc -> showSDocUnqual $ ppr iftc)
                            $ map fromJust
                                $ filter isJust
                                    $ ifInstTys ifaceInst
    in [Descr
                    {   descrName'       =   className
                    ,   typeInfo'        =   BS.empty
                    ,   descrModu'       =   pm
                    ,   mbLocation'      =   Nothing
                    ,   mbComment'       =   Nothing
                    ,   details'         =   InstanceDescr {binds = dataNames}}]


extractUsages :: Usage -> (ModuleName, Set Symbol)
extractUsages (UsagePackageModule usg_mod _ ) =
    let name    =   (fromJust . simpleParse . moduleNameString) (moduleName usg_mod)
    in (name, Set.fromList [])
extractUsages (UsageHomeModule usg_mod_name _ usg_entities _) =
    let name    =   (fromJust . simpleParse . moduleNameString) usg_mod_name
        ids     =   map (showSDocUnqual . ppr . fst) usg_entities
    in (name, Set.fromList ids)

filterExtras, filterExtras' :: String -> String
filterExtras ('{':'-':r)                =   filterExtras' r
filterExtras ('R':'e':'c':'F':'l':'a':'g':r)
                                        =   filterExtras (skipNextWord r)
filterExtras ('G':'e':'n':'e':'r':'i':'c':'s':':':r)
                                        =   filterExtras (skipNextWord r)
filterExtras ('F':'a':'m':'i':'l':'y':'I':'n':'s':'t':'a':'n':'c':'e':':':r)
                                        =   filterExtras (skipNextWord r)
filterExtras (c:r)                      =   c : filterExtras r
filterExtras []                         =   []

filterExtras' ('-':'}':r)   =   filterExtras r
filterExtras' (_:r)         =   filterExtras' r
filterExtras' []            =   []

skipNextWord, skipNextWord' :: String -> String
skipNextWord (a:r)
    | isSpace a             =   skipNextWord r
    | otherwise             =   skipNextWord' r
skipNextWord []             =   []

skipNextWord'(a:r)
        | a == '\n'         =   r
        | isSpace a         =   a:r
        | otherwise         =   skipNextWord' r
skipNextWord' []            =   []

writeExtracted :: MonadIO m => FilePath -> Bool -> Bool -> PackageDescr -> m ()
writeExtracted dirPath writeAscii isWorkingPackage pd = liftIO $ do
    let filePath    = dirPath </> fromPackageIdentifier (packagePD pd) ++
                        (if isWorkingPackage then ".packw" else ".pack")
    if writeAscii
        then writeFile (filePath ++ "dpg") (show pd)
        else encodeFileSer filePath (metadataVersion, pd)

