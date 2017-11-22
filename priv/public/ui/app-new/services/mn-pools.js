var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnPools = (function () {
  "use strict";

  var launchID =  (new Date()).valueOf() + '-' + ((Math.random() * 65536) >> 0);

  var MnPools =
      ng.core.Injectable()
      .Class({
        constructor: [
          ng.common.http.HttpClient,
          mn.pipes.MnParseVersion,
          function MnPoolsService(http, mnParseVersionPipe) {
            this.http = http;
            this.stream = {};
            this.stream.getSuccess =
              this.get()
              .filter(function (rv) {
                return !(rv instanceof ng.common.http.HttpErrorResponse);
              })
              .publishReplay(1)
              .refCount();

            this.stream.isEnterprise =
              this.stream
              .getSuccess
              .pluck("isEnterprise");

            this.stream.majorMinorVersion =
              this.stream.getSuccess
              .pluck("implementationVersion")
              .map(mnParseVersionPipe.transform.bind(mnParseVersionPipe))
              .map(function (rv) {
                return rv[0].split('.').splice(0,2).join('.');
              });
          }],
        get: get,
      });

  return MnPools;

  function get(mnHttpParams) {
    return this.http
      .get('/pools').map(function (pools) {
        pools.isInitialized = !!pools.pools.length;
        pools.launchID = pools.uuid + '-' + launchID;
        return pools;
      }).catch(function (resp) {
        return Rx.Observable.of(resp);
      });
  }
})();
