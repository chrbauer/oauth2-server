{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE RecordWildCards   #-}

-- |
-- Description: Foundation code for the Yesod web-app.
module Network.OAuth2.Server.Foundation where

import           Blaze.ByteString.Builder
import           Control.Concurrent.STM
import qualified Data.Text.Encoding as T
import           Language.Haskell.TH
import           Network.Wai
import           URI.ByteString
import           Web.ClientSession
import           Yesod.Core
import qualified Yesod.Static as Static
import           Yesod.Routes.TH.Types

import           Network.OAuth2.Server.Store.Base
import           Network.OAuth2.Server.Types

-- Include default resources resources.
--
-- This will define the following variables:
--
-- - @semantic_css@
-- - @stylesheet_css@
Static.staticFiles "static"

-- | Yesod application type.
--
--   Values of this type carry the internal state of the OAuth2 Server
--   application.
data OAuth2Server where
    OAuth2Server :: TokenStore ref =>
                    { serverTokenStore   :: ref
                    , serverOptions      :: ServerOptions
                    , serverEventChannel :: (TChan GrantEvent)
                    , serverStatics      :: Static.Static
                    } -> OAuth2Server

-- This generates the routing types. The routes used are re-exported,
-- so that the dispatch function can be derived independently.
-- It Has to be in the same block and can't be a declaration, as this
-- would violate the GHC stage restriction.
do let routes = [parseRoutes|
           /oauth2/token     TokenEndpointR     POST
           /oauth2/authorize AuthorizeEndpointR GET POST
           /oauth2/verify    VerifyEndpointR    POST
           /                 BaseR
           /tokens/#TokenID  ShowTokenR         GET
           /tokens           TokensR            GET POST
           /static           StaticR      Static.Static serverStatics
           /healthcheck      HealthCheckR
           |]
   routes_name <- newName "routes"
   routes_type <- sigD routes_name [t| [ResourceTree String] |]
   routes_dec <- valD (varP routes_name) (normalB [e|routes|]) []
   decs <- mkYesodData "OAuth2Server" routes
   return $ routes_type:routes_dec:decs

instance Yesod OAuth2Server where
    approot = ApprootMaster $ \OAuth2Server{serverOptions=ServerOptions{..}} ->
        maybe "" (T.decodeUtf8 . toByteString . serializeURIRef) optServiceAppRoot

    errorHandler = defaultErrorHandler

    defaultLayout contents = do
        PageContent the_title head_tags body_tags <- widgetToPageContent $ do
            addStylesheet $ StaticR semantic_css
            addStylesheet $ StaticR stylesheet_css
            contents

        withUrlRenderer [hamlet|
        $doctype 5
        <html lang="en">
            <head>
                <meta charset="UTF-8">
                <title>#{the_title}
                <meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
                <link rel="stylesheet" href=@{StaticR semantic_css}>
                <link rel="stylesheet" href=@{StaticR stylesheet_css}>
                ^{head_tags}
            <body>
                <div id="app">
                    <div class="ui page grid">
                        <header class="sixteen wide column">
                            <div class="centered ten wide column">
                                <img class="ui image centered" src="@{StaticR logo_png}" alt="Token Server">
                                <h1 class="ui centered header">Token Server
                        <section class="sixteen wide column">
                            <div class="ui stackable grid">
                                <div class="centered wide column">
                                    ^{body_tags}
    |]

    maximumContentLength _ _ = Just $ 128 * 1024 -- 128 kilobytes

    yesodMiddleware handler = do
        route <- getCurrentRoute
        case route of
            Just (StaticR _) -> return ()
            Just _ -> do
                -- Required for all endpoints containing sensitive information.
                -- https://tools.ietf.org/html/rfc6749#section-5.1
                addHeader "Cache-Control" "no-store"
                addHeader "Pragma" "no-cache"
            Nothing -> return ()
        handler

    makeSessionBackend OAuth2Server{serverOptions=ServerOptions{..}} = do
        key <- getKey optKeyFile
        (getCachedDate, _closeDateCacher) <- clientSessionDateCacher optSessionExpiry
        let SessionBackend load_session = clientSessionBackend key getCachedDate
        let discard_session _ = return (mempty, const $ return [])
        -- Disable session backend for JSON endpoints and static.
        let should_session req = case pathInfo req of
                "static":_          -> False
                ["oauth2","token"]  -> False
                ["oauth2","verify"] -> False
                _                   -> True
        return $ Just $ SessionBackend $
            \req -> if should_session req
                        then load_session req
                        else discard_session req
