{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE QuasiQuotes #-}
{-# OPTIONS_GHC -fno-warn-missing-fields #-}
module Text.Lucius
    ( -- * Parsing
      lucius
    , luciusFile
    , luciusFileDebug
    , luciusFileReload
      -- ** Runtime
    , luciusRT
    , luciusRT'
    , luciusRTMinified
    , -- * Datatypes
      Css
    , CssUrl
      -- * Type class
    , ToCss (..)
      -- * Rendering
    , renderCss
    , renderCssUrl
      -- * ToCss instances
      -- ** Color
    , Color (..)
    , colorRed
    , colorBlack
      -- ** Size
    , mkSize
    , AbsoluteUnit (..)
    , AbsoluteSize (..)
    , absoluteSize
    , EmSize (..)
    , ExSize (..)
    , PercentageSize (..)
    , percentageSize
    , PixelSize (..)
      -- * Internal
    , parseTopLevels
    , luciusUsedIdentifiers
    ) where

import Text.CssCommon
import Text.Shakespeare.Base
import Language.Haskell.TH.Quote (QuasiQuoter (..))
import Language.Haskell.TH.Syntax
import Data.Text (Text, unpack)
import qualified Data.Text.Lazy as TL
import Text.ParserCombinators.Parsec hiding (Line)
import Text.Css
import Data.Char (isSpace, toLower, toUpper)
import Numeric (readHex)
import Control.Applicative ((<$>))
import Control.Monad (when, unless)
import Data.Either (partitionEithers)
import Data.Monoid (mconcat)
import Data.List (isSuffixOf)

-- |
--
-- >>> renderCss ([lucius|foo{bar:baz}|] undefined)
-- "foo{bar:baz}"
lucius :: QuasiQuoter
lucius = QuasiQuoter { quoteExp = luciusFromString }

luciusFromString :: String -> Q Exp
luciusFromString s =
    topLevelsToCassius
  $ either (error . show) id $ parse parseTopLevels s s

whiteSpace :: Parser ()
whiteSpace = many whiteSpace1 >> return ()

whiteSpace1 :: Parser ()
whiteSpace1 =
    ((oneOf " \t\n\r" >> return ()) <|> (parseComment >> return ()))

parseBlock :: Parser (Block Unresolved)
parseBlock = do
    sel <- parseSelector
    _ <- char '{'
    whiteSpace
    pairsBlocks <- parsePairsBlocks id
    let (pairs, blocks) = partitionEithers pairsBlocks
    whiteSpace
    return $ Block sel pairs blocks

parseSelector :: Parser (Selector Unresolved)
parseSelector =
    go id
  where
    go front = do
        c <- parseContents "{,"
        let front' = front . (:) (trim c)
        (char ',' >> go front') <|> return (front' [])

trim :: Contents -> Contents
trim =
    reverse . trim' False . reverse . trim' True
  where
    trim' _ [] = []
    trim' b (ContentRaw s:rest) =
        let s' = trimS b s
         in if null s' then trim' b rest else ContentRaw s' : rest
    trim' _ x = x
    trimS True = dropWhile isSpace
    trimS False = reverse . dropWhile isSpace . reverse

type PairBlock = Either (Attr Unresolved) (Block Unresolved)
parsePairsBlocks :: ([PairBlock] -> [PairBlock]) -> Parser [PairBlock]
parsePairsBlocks front = (char '}' >> return (front [])) <|> (do
    isBlock <- lookAhead checkIfBlock
    x <- if isBlock
            then (do
                b <- parseBlock
                whiteSpace
                return $ Right b)
            else Left <$> parsePair
    parsePairsBlocks $ front . (:) x)
  where
    checkIfBlock = do
        skipMany $ noneOf "#@{};"
        (parseHash >> checkIfBlock)
            <|> (parseAt >> checkIfBlock)
            <|> (char '{' >> return True)
            <|> (oneOf ";}" >> return False)
            <|> (anyChar >> checkIfBlock)
            <|> fail "checkIfBlock"

parsePair :: Parser (Attr Unresolved)
parsePair = do
    key <- parseContents ":"
    _ <- char ':'
    whiteSpace
    val <- parseContents ";}"
    (char ';' >> return ()) <|> return ()
    whiteSpace
    return $ Attr key val

parseContents :: String -> Parser Contents
parseContents = many1 . parseContent

parseContent :: String -> Parser Content
parseContent restricted =
    parseHash' <|> parseAt' <|> parseComment <|> parseBack <|> parseChar
  where
    parseHash' = either ContentRaw ContentVar `fmap` parseHash
    parseAt' =
        either ContentRaw go `fmap` parseAt
      where
        go (d, False) = ContentUrl d
        go (d, True) = ContentUrlParam d
    parseBack = try $ do
        _ <- char '\\'
        hex <- atMost 6 $ satisfy isHex
        (int, _):_ <- return $ readHex $ dropWhile (== '0') hex
        when (length hex < 6) $
            ((string "\r\n" >> return ()) <|> (satisfy isSpace >> return ()))
        return $ ContentRaw [toEnum int]
    parseChar = (ContentRaw . return) `fmap` noneOf restricted

isHex :: Char -> Bool
isHex c =
    ('0' <= c && c <= '9') ||
    ('A' <= c && c <= 'F') ||
    ('a' <= c && c <= 'f')

atMost :: Int -> Parser a -> Parser [a]
atMost 0 _ = return []
atMost i p = (do
    c <- p
    s <- atMost (i - 1) p
    return $ c : s) <|> return []

parseComment :: Parser Content
parseComment = do
    _ <- try $ string "/*"
    _ <- manyTill anyChar $ try $ string "*/"
    return $ ContentRaw ""

luciusFile :: FilePath -> Q Exp
luciusFile fp = do
    contents <- fmap TL.unpack $ qRunIO $ readUtf8File fp
    luciusFromString contents

luciusFileDebug, luciusFileReload :: FilePath -> Q Exp
luciusFileDebug = cssFileDebug False [|parseTopLevels|] parseTopLevels
luciusFileReload = luciusFileDebug

parseTopLevels :: Parser [TopLevel Unresolved]
parseTopLevels =
    go id
  where
    go front = do
        let string' s = string s >> return ()
            ignore = many (whiteSpace1 <|> string' "<!--" <|> string' "-->")
                        >> return ()
        ignore
        tl <- ((charset <|> media <|> impor <|> topAtBlock <|> var <|> fmap TopBlock parseBlock) >>= \x -> go (front . (:) x))
            <|> (return $ map compressTopLevel $ front [])
        ignore
        return tl
    charset = do
        try $ stringCI "@charset "
        cs <- parseContents ";"
        _ <- char ';'
        return $ TopAtDecl "charset" cs
    media = do
        try $ stringCI "@media "
        selector <- parseContents "{"
        _ <- char '{'
        b <- parseBlocks id
        return $ TopAtBlock "media" selector b
    impor = do
        try $ stringCI "@import ";
        val <- parseContents ";"
        _ <- char ';'
        return $ TopAtDecl "import" val
    var = try $ do
        _ <- char '@'
        isPage <- (try $ string "page " >> return True) <|>
                  (try $ string "font-face " >> return True) <|>
                    return False
        when isPage $ fail "page is not a variable"
        k <- many1 $ noneOf ":"
        _ <- char ':'
        v <- many1 $ noneOf ";"
        _ <- char ';'
        let trimS = reverse . dropWhile isSpace . reverse . dropWhile isSpace
        return $ TopVar (trimS k) (trimS v)
    topAtBlock = do
        (name, selector) <- try $ do
            _ <- char '@'
            name <- many1 $ noneOf " \t"
            _ <- many1 $ oneOf " \t"
            unless ("keyframes" `isSuffixOf` name) $ fail "only accepting keyframes"
            selector <- parseContents "{"
            _ <- char '{'
            return (name, selector)
        b <- parseBlocks id
        return $ TopAtBlock name selector b
    parseBlocks front = do
        whiteSpace
        (char '}' >> return (map compressBlock $ front []))
            <|> (parseBlock >>= \x -> parseBlocks (front . (:) x))

stringCI :: String -> Parser ()
stringCI [] = return ()
stringCI (c:cs) = (char (toLower c) <|> char (toUpper c)) >> stringCI cs

luciusRT' :: TL.Text
          -> Either String ([(Text, Text)] -> Either String [TopLevel Resolved])
luciusRT' tl =
    case parse parseTopLevels (TL.unpack tl) (TL.unpack tl) of
        Left s -> Left $ show s
        Right tops -> Right $ \scope -> go scope tops
  where
    go :: [(Text, Text)]
       -> [TopLevel Unresolved]
       -> Either String [TopLevel Resolved]
    go _ [] = Right []
    go scope (TopAtDecl dec cs':rest) = do
        let scope' = map goScope scope
            render = error "luciusRT has no URLs"
        cs <- mapM (contentToBuilderRT scope' render) cs'
        rest' <- go scope rest
        Right $ TopAtDecl dec (mconcat cs) : rest'
    go scope (TopBlock b:rest) = do
        b' <- goBlock scope b
        rest' <- go scope rest
        Right $ map TopBlock b' ++ rest'
    go scope (TopAtBlock name m' bs:rest) = do
        let scope' = map goScope scope
            render = error "luciusRT has no URLs"
        m <- mapM (contentToBuilderRT scope' render) m'
        bs' <- mapM (goBlock scope) bs
        rest' <- go scope rest
        Right $ TopAtBlock name (mconcat m) (concat bs') : rest'
    go scope (TopVar k v:rest) = go ((pack k, pack v):scope) rest

    goBlock :: [(Text, Text)]
            -> Block Unresolved
            -> Either String [Block Resolved]
    goBlock scope =
        either Left (Right . ($[])) . blockRuntime scope' (error "luciusRT has no URLs")
      where
        scope' = map goScope scope

    goScope (k, v) = (DerefIdent (Ident $ unpack k), CDPlain $ fromText v)

luciusRT :: TL.Text -> [(Text, Text)] -> Either String TL.Text
luciusRT tl scope = either Left (Right . renderCss . CssWhitespace) $ either Left ($ scope) (luciusRT' tl)

-- | Same as 'luciusRT', but output has no added whitespace.
--
-- Since 1.0.3
luciusRTMinified :: TL.Text -> [(Text, Text)] -> Either String TL.Text
luciusRTMinified tl scope = either Left (Right . renderCss . CssNoWhitespace) $ either Left ($ scope) (luciusRT' tl)

-- | Determine which identifiers are used by the given template, useful for
-- creating systems like yesod devel.
luciusUsedIdentifiers :: String -> [(Deref, VarType)]
luciusUsedIdentifiers = cssUsedIdentifiers False parseTopLevels
