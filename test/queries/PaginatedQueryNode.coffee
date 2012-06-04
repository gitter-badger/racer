# TODO Ensure there's a cache check for every publish check
PaginatedQueryNode = require '../../lib/queries/PaginatedQueryNode'
transaction = require '../../lib/transaction'
expect = require 'expect.js'
sinon = require 'sinon'
{publishArgs} = require './QueryNode'
Memory = require '../../lib/Memory'
DbMemory = require('../../lib/adapters/db-memory').adapter
{deepCopy} = require '../../lib/util'

describe 'PaginatedQueryNode', ->

  nextVer = 1
  nextTxnId = 1
  createTxn = (method, args...) ->
    params = {}
    params.method = method
    params.args = args
    params.ver = nextVer++
    params.id = 'txnid' + nextTxnId++
    return transaction.create params

  describe '#results(db, cb)', ->
    it 'should pass back the results in the db'

  describe '#maybePublish(newDoc, oldDoc, txn, services, cb)', ->

    memory = new Memory

    beforeEach ->
      @pubSub = publish: sinon.spy()
      @store =
        _db: @db = new DbMemory

    it 'should not publish any events if the document does not pass the filter', ->
      queryJson =
        from: 'users'
        gte: age: 20
        lte: age: 30
        sort: ['age', 'asc', 'name', 'desc']
        skip: 0
        limit: 3
      qnode = new PaginatedQueryNode queryJson
      doc = id: 'a', name: 'Brian', age: 16
      txn = createTxn('set', 'users.a', doc)
      transaction.applyTxn txn, @db._data, memory
      expect(@pubSub.publish).to.have.callCount(0)

    describe 'for first page', ->
      queryJson =
        from: 'users'
        gte: age: 20
        lte: age: 30
        sort: ['age', 'asc', 'name', 'desc']
        skip: 0
        limit: 3

      beforeEach -> @qnode = new PaginatedQueryNode queryJson

      describe 'creating a document belonging to the page', ->
        beforeEach ->
          @doc = id: 'a', name: 'Brian', age: 21
          @txn = createTxn('set', 'users.a', @doc)

        describe 'when the cache is undefined', ->
          beforeEach ->
            transaction.applyTxn @txn, @db._data, memory
            @qnode.maybePublish @doc, undefined, @txn, {@store, @pubSub}

          it 'should publish an "addDoc" event', ->
            expect(@pubSub.publish).to.be.calledOnce()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @doc, ver: transaction.getVer @txn})

          it 'should not duplicate the document in the cache', ->
            expect(@qnode._cache).to.have.length(1)

        describe 'when the result set cardinality < limit', ->

          describe 'when the cache is warmed', ->
            beforeEach (done) ->
              @qnode.results @db, (err, found) =>
                # Cache is now warmed
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish @doc, undefined, @txn, {@store, @pubSub}
                done(err)

            it 'should publish an "addDoc" event', ->
              expect(@pubSub.publish).to.be.calledOnce()
              expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @doc, ver: transaction.getVer @txn})

        describe 'when the result set cardinality already was === limit', ->
          beforeEach ->
            @db._data.world.users =
              'x': { id: 'x', name: 'Brock', age: 23 }
              'y': { id: 'y', name: 'Boris', age: 24 }
              'z': { id: 'z', name: 'Ben',   age: 25 }

          describe 'when the cache is warmed', ->
            beforeEach (done) ->
              @qnode.results @db, (err, found) =>
                # Cache is now warmed
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish @doc, undefined, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "rmDoc" and an "addDoc" event', ->
              expect(@pubSub.publish).to.be.calledTwice()
              expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'z', ver: transaction.getVer @txn})
              expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @doc, ver: transaction.getVer @txn})

          describe 'creating a document belonging to the next page', ->
            beforeEach (done) ->
              @doc = id: 'a', name: 'Brian', age: 27
              txn = createTxn('set', 'users.a', @doc)
              @qnode.results @db, (err, found) =>
                transaction.applyTxn txn, @db._data, memory
                @qnode.maybePublish @doc, undefined, txn, {@store, @pubSub}
                done(err)

            it 'should not publish any events', ->
              expect(@pubSub.publish).to.have.callCount(0)

            it 'should not alter the cache', ->
              expect(@qnode._cache).to.have.length(3)
              expect(@qnode._cache.map (x) -> x.id).to.eql ['x', 'y', 'z']


      describe 'modifying a doc such that it no longer satisfies the non-paginated filter', ->

        it 'should do nothing if the document came from a later page', ->
          origDoc = id: 'z', name: 'Z', age: 23
          @db._data.world.users =
            w: {id: 'w', name: 'W', age: 20}
            x: {id: 'x', name: 'X', age: 21}
            y: {id: 'y', name: 'Y', age: 22}
            z: newDoc = deepCopy origDoc

          @qnode.results @db, (err, found) =>
            # Cache is now warmed
            txn = createTxn 'set', 'users.z.age', 40
            transaction.applyTxn txn, @db._data, memory
            @qnode.maybePublish newDoc, origDoc, txn, {@store, @pubSub}

            expect(@pubSub.publish).to.have.callCount(0)

        describe 'when the doc was in the current page', ->

          describe 'when there is no page 2', ->
            beforeEach (done) ->
              origDoc = id: 'y', name: 'Y', age: 22
              @db._data.world.users =
                w: {id: 'w', name: 'W', age: 20}
                x: {id: 'x', name: 'X', age: 21}
                y: newDoc = deepCopy origDoc

              @qnode.results @db, (err, found) =>
                @txn = createTxn 'set', 'users.y.age', 40
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish newDoc, origDoc, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "rmDoc" event with the non-satisfying doc', ->
              expect(@pubSub.publish).to.be.calledOnce()
              expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'y', ver: transaction.getVer @txn})

          describe 'when there is a page 2', ->
            beforeEach (done) ->
              origDoc = id: 'y', name: 'Y', age: 22
              @db._data.world.users =
                w: {id: 'w', name: 'W', age: 20}
                x: {id: 'x', name: 'X', age: 21}
                y: newDoc = deepCopy origDoc
                z: @z = {id: 'z', name: 'Z', age: 23}

              @qnode.results @db, (err, found) =>
                @txn = createTxn 'set', 'users.y.age', 40
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish newDoc, origDoc, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "rmDoc" event with the non-satisfying doc', ->
              expect(@pubSub.publish).to.be.calledTwice()
              expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'y', ver: transaction.getVer @txn})

            it 'should publish an "addDoc" event with the first doc of the next page', ->
              expect(@pubSub.publish).to.be.calledTwice()
              expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @z, ver: transaction.getVer @txn})


    describe 'for page 2 (and beyond by induction)', ->
      queryJson =
        from: 'users'
        gte: age: 20
        lte: age: 30
        sort: ['age', 'asc', 'name', 'desc']
        skip: 3
        limit: 3

      beforeEach ->
        @qnode = new PaginatedQueryNode queryJson
        # Make sure there is data that should belong to page 1
        @db._data.world.users =
          'x': @x = { id: 'x', name: 'X', age: 20 }
          'y': @y = { id: 'y', name: 'Y', age: 21 }
          'z': @z = { id: 'z', name: 'Z', age: 22 }

      describe 'creating a document that belongs on a prior page', ->

        describe 'when the cache length is 0', ->

          beforeEach (done) ->
            @doc = id: 'a', name: 'A', age: 20
            @txn = createTxn 'set', 'users.a', @doc
            @qnode.results @db, (err, found) =>
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @doc, undefined, @txn, {@store, @pubSub}
              done(err)

          it 'should bring the last doc of the prev page into the cache and publish it with the "addDoc" event', ->
            expect(@pubSub.publish).to.be.calledOnce()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @z, ver: transaction.getVer @txn})

        describe 'when 0 < cache length < limit', ->
          beforeEach (done) ->
            @db._data.world.users.w = @w = { id: 'w', name: 'W', age: 23}
            @doc = id: 'a', name: 'A', age: 20
            @txn = createTxn 'set', 'users.a', @doc
            @qnode.results @db, (err, found) =>
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @doc, undefined, @txn, {@store, @pubSub}
              done(err)

          it 'should bring the last doc of the prev page into the cache and publish it with the "addDoc" event', ->
            expect(@pubSub.publish).to.be.calledOnce()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @z, ver: transaction.getVer @txn})


        describe 'when the cache length === limit', ->
          beforeEach (done) ->
            @db._data.world.users.u = @u = { id: 'u', name: 'U', age: 23}
            @db._data.world.users.v = @v = { id: 'v', name: 'V', age: 24}
            @db._data.world.users.w = @w = { id: 'w', name: 'W', age: 25}
            @doc = id: 'a', name: 'A', age: 20
            @txn = createTxn 'set', 'users.a', @doc
            @qnode.results @db, (err, found) =>
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @doc, undefined, @txn, {@store, @pubSub}
              done(err)

          it 'should bring the last doc of the prev page into the cache and publish it with the "addDoc" event', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @z, ver: transaction.getVer @txn})

          it 'should get rid of the last doc of the curr page from the cache and publish it with the "rmDoc" event', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'w', ver: transaction.getVer @txn})

      describe 'modifying a doc such that it no longer satisfies the non-paginated filter', ->
        describe 'when the doc was in a prior page', ->
          describe 'when there is no next page', ->
            beforeEach (done) ->
              origDoc = {id: 'a', name: 'A', age: 20}
              @db._data.world.users =
                a: newDoc = deepCopy origDoc
                b: {id: 'b', name: 'B', age: 21}
                c: {id: 'c', name: 'C', age: 22}
                d: {id: 'd', name: 'D', age: 23}

              @qnode.results @db, (err, found) =>
                expect(@qnode._cache).to.have.length(1)
                @txn = createTxn 'set', 'users.a.age', 16
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish newDoc, origDoc, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "rmDoc" with the first doc that we remove from the cache', ->
              expect(@pubSub.publish).to.be.calledOnce()
              expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'd', ver: transaction.getVer @txn})

            it 'should remove the first doc from the cache', ->
              expect(@qnode._cache).to.be.empty()

          describe 'when there is a next page', ->
            beforeEach (done) ->
              origDoc = {id: 'a', name: 'A', age: 20}
              @db._data.world.users =
                a: @newDoc = deepCopy origDoc
                b: {id: 'b', name: 'B', age: 21}
                c: {id: 'c', name: 'C', age: 22}
                d: {id: 'd', name: 'D', age: 23} # In page
                e: {id: 'e', name: 'E', age: 24} # In page
                f: {id: 'f', name: 'F', age: 25} # In page
                g: @g = {id: 'g', name: 'G', age: 26}

              @qnode.results @db, (err, found) =>
                expect(@qnode._cache).to.have.length(3)
                @txn = createTxn 'set', 'users.a.age', 16
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "rmDoc" with the first doc that we remove from the cache', ->
              expect(@pubSub.publish).to.be.calledTwice()
              expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'd', ver: transaction.getVer @txn})

            it 'should publish an "addDoc" with the first doc from the next page', ->
              expect(@pubSub.publish).to.be.calledTwice()
              expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @g, ver: transaction.getVer @txn})

            it 'should remove the first doc from the cache', ->
              expect(@qnode._cache[0]).to.not.eql @newDoc

            it 'should add the doc that *was* first on the next page, to the cache', ->
              expect(@qnode._cache[2]).to.eql @g

  # maybePublish(newDoc, oldDoc, txn, services, cb)
    # for page 2 (and beyond by induction)
      describe 'modifying a doc and it still satisfies the query', ->
        it 'should do nothing if doc moves from prior page to prior page', ->
          origDoc = {id: 'a', name: 'A', age: 20}
          @db._data.world.users =
            a: newDoc = deepCopy origDoc
            b: {id: 'b', name: 'B', age: 21}
            c: {id: 'c', name: 'C', age: 22}
            d: {id: 'd', name: 'D', age: 23}

          @qnode.results @db, (err, found) =>
            origCache = @qnode._cache.slice()
            expect(@qnode._cache).to.have.length(1)
            @txn = createTxn 'set', 'users.a.age', 22
            transaction.applyTxn @txn, @db._data, memory
            @qnode.maybePublish newDoc, origDoc, @txn, {@store, @pubSub}
            expect(@pubSub.publish).to.have.callCount(0)
            expect(@qnode._cache).to.eql(origCache)

  # maybePublish(newDoc, oldDoc, txn, services, cb)
    # for page 2 (and beyond by induction)
      # modifying a doc and it still satisfies the query
        describe 'if doc moves from prior to curr page', ->
          # TODO Saturated vs non-saturated
          beforeEach (done) ->
            origDoc = {id: 'a', name: 'A', age: 20}
            @db._data.world.users =
              a: @newDoc = deepCopy origDoc
              b: {id: 'b', name: 'B', age: 21}
              c: {id: 'c', name: 'C', age: 22}
              d: @d = {id: 'd', name: 'D', age: 23}

            @qnode.results @db, (err, found) =>
              origCache = @qnode._cache.slice()
              expect(@qnode._cache).to.have.length(1)
              @txn = createTxn 'set', 'users.a.age', 24
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
              done(err)

          it 'should publish a "rmDoc" of the first doc on the old page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'd', ver: transaction.getVer @txn})

          it 'should remove the first doc from the cache', ->
            expect(@qnode._cache[0]).to.not.contain @g

          it 'should publish an "addDoc" with the altered doc', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @newDoc, ver: transaction.getVer @txn})

          it 'should add the altered doc to the cache', ->
            expect(@qnode._cache).to.contain @newDoc

  # maybePublish(newDoc, oldDoc, txn, services, cb)
    # for page 2 (and beyond by induction)
      # modifying a doc and it still satisfies the query
        describe 'if doc moves from prior to later page', ->
          beforeEach (done) ->
            origDoc = id: 'c', name: 'C', age: 22
            @db._data.world.users =
              a: {id: 'a', name: 'A', age: 20}
              b: {id: 'b', name: 'B', age: 21}
              c: @newDoc = deepCopy origDoc
              d: @d = {id: 'd', name: 'D', age: 23}
              e: @e = {id: 'e', name: 'E', age: 24}
              f: @f = {id: 'f', name: 'F', age: 25}
              g: @g = {id: 'g', name: 'G', age: 26}

            @qnode.results @db, (err, found) =>
              @txn = createTxn 'set', 'users.c.age', 27

              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
              done(err)

          it 'should publish a "rmDoc" of the first doc on the old page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'd', ver: transaction.getVer @txn})

          it 'should remove the first doc in the cache', ->
            expect(@qnode._cache).to.not.contain @d

          it 'should publish an "addDoc" of the first doc of the old next page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @g, ver: transaction.getVer @txn})

          it 'should insert the first doc of the old next page at cache[cache.length-1]', ->
            expect(@qnode._cache).to.eql [@e, @f, @g]

# maybePublish(newDoc, oldDoc, txn, services, cb)
  # for page 2 (and beyond by induction)
    # modifying a doc and it still satisfies the query
        describe 'if doc moves from curr to prior page', ->
          beforeEach (done) ->
            origDoc = id: 'e', name: 'E', age: 25
            @db._data.world.users =
              a: {id: 'a', name: 'A', age: 20}
              b: {id: 'b', name: 'B', age: 21}
              c: @c = {id: 'c', name: 'C', age: 22}
              d: @d = {id: 'd', name: 'D', age: 24}
              e: @newDoc = deepCopy origDoc
              f: @f = {id: 'f', name: 'F', age: 26}

            @qnode.results @db, (err, found) =>
              @txn = createTxn 'set', 'users.e.age', 20

              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
              done(err)

          it 'should publish a "rmDoc" with the altered doc', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'e', ver: transaction.getVer @txn})

          it 'should remove the altered doc from the cache', ->
            expect(@qnode._cache).to.not.contain @newDoc

          it 'should publish an "addDoc" with the last doc of the old prev page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @c, ver: transaction.getVer @txn})

          it 'should insert the last doc of the old prev page to cache[0]', ->
            expect(@qnode._cache).to.contain @c
            expect(@qnode._cache).to.eql [@c, @d, @f]

# maybePublish(newDoc, oldDoc, txn, services, cb)
  # for page 2 (and beyond by induction)
    # modifying a doc and it still satisfies the query
        describe 'if doc moves within the curr page', ->
          describe 'to inside the cache boundaries', ->
            beforeEach (done) ->
              origDoc = id: 'f', name: 'F', age: 27
              @db._data.world.users =
                a: {id: 'a', name: 'A', age: 20}
                b: {id: 'b', name: 'B', age: 21}
                c: {id: 'c', name: 'C', age: 22}
                d: @d = {id: 'd', name: 'D', age: 24}
                e: @e = {id: 'e', name: 'E', age: 26}
                f: @newDoc = deepCopy origDoc
              @qnode.results @db, (err, found) =>
                @txn = createTxn 'set', 'users.f.age', 25
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "txn" with the txn that caused the mutation', ->
              expect(@pubSub.publish).to.be.calledOnce()
              expect(@pubSub.publish).to.be.calledWith publishArgs('txn', @qnode.channel, @txn)

            it 'should move the doc to a different place in the cache to keep sorted order', ->
              expect(@qnode._cache).to.eql [@d, @newDoc, @e]

          describe 'to the edges', ->
            beforeEach (done) ->
              origDoc = id: 'e', name: 'E', age: 25
              @db._data.world.users =
                a: {id: 'a', name: 'A', age: 20}
                b: {id: 'b', name: 'B', age: 21}
                c: {id: 'c', name: 'C', age: 22}
                d: @d = {id: 'd', name: 'D', age: 24}
                e: @newDoc = deepCopy origDoc
                f: @f = {id: 'f', name: 'F', age: 26}
                g: @g = {id: 'g', name: 'G', age: 27}
              @qnode.results @db, (err, found) =>
                @txn = createTxn 'set', 'users.e.age', 23
                transaction.applyTxn @txn, @db._data, memory
                @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
                done(err)

            it 'should publish a "txn" with the txn that caused the mutation', ->
              expect(@pubSub.publish).to.be.calledOnce()
              expect(@pubSub.publish).to.be.calledWith publishArgs('txn', @qnode.channel, @txn)

            it 'should move the doc to a different place in the cache to keep sorted order', ->
              expect(@qnode._cache).to.eql [@newDoc, @d, @f]

# maybePublish(newDoc, oldDoc, txn, services, cb)
  # for page 2 (and beyond by induction)
    # modifying a doc and it still satisfies the query
        describe 'if doc moves from curr to later page', ->
          beforeEach (done) ->
            origDoc = id: 'e', name: 'E', age: 24
            @db._data.world.users =
              a: {id: 'a', name: 'A', age: 20}
              b: {id: 'b', name: 'B', age: 21}
              c: {id: 'c', name: 'C', age: 22}
              d: {id: 'd', name: 'D', age: 23}
              e: @newDoc = deepCopy origDoc
              f: {id: 'f', name: 'F', age: 25}
              g: @g = {id: 'g', name: 'G', age: 26}
            @qnode.results @db, (err, found) =>
              @txn = createTxn 'set', 'users.e.age', 27
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
              done(err)

          it 'should publish a "rmDoc" with the altered doc', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'e', ver: transaction.getVer @txn})

          it 'should remove the altered doc from the cache', ->
            expect(@qnode._cache).to.not.contain @newDoc

          it 'should publish an "addDoc" with the first doc of the old next page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @g, ver: transaction.getVer @txn})

          it 'should insert the first doc of the old next page at cache[cache.length-1]', ->
            expect(@qnode._cache[2]).to.eql @g

# maybePublish(newDoc, oldDoc, txn, services, cb)
  # for page 2 (and beyond by induction)
    # modifying a doc and it still satisfies the query
        describe 'if doc moves from later to prior page', ->
          beforeEach (done) ->
            origDoc = id: 'g', name: 'G', age: 26
            @db._data.world.users =
              a: {id: 'a', name: 'A', age: 20}
              b: {id: 'b', name: 'B', age: 21}
              c: @c = {id: 'c', name: 'C', age: 22}
              d: {id: 'd', name: 'D', age: 23}
              e: {id: 'e', name: 'E', age: 24}
              f: @f = {id: 'f', name: 'F', age: 25}
              g: @newDoc = deepCopy origDoc
            @qnode.results @db, (err, found) =>
              @txn = createTxn 'set', 'users.g.age', 20
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
              done(err)

          it 'should publish a "rmDoc" with the last doc of the old curr page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'f', ver: transaction.getVer @txn})
          it 'should remove the last doc in the cache', ->
            expect(@qnode._cache).to.not.contain @f

          it 'should publish an "addDoc" with the last doc of the old prev page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @c, ver: transaction.getVer @txn})

          it 'should insert the last doc of the old prev page at cache[0]', ->
            expect(@qnode._cache[0]).to.eql @c

# maybePublish(newDoc, oldDoc, txn, services, cb)
  # for page 2 (and beyond by induction)
    # modifying a doc and it still satisfies the query
        describe 'if doc moves from later to curr page', ->
          beforeEach (done) ->
            origDoc = id: 'g', name: 'G', age: 26
            @db._data.world.users =
              a: {id: 'a', name: 'A', age: 20}
              b: {id: 'b', name: 'B', age: 21}
              c: {id: 'c', name: 'C', age: 22}
              d: {id: 'd', name: 'D', age: 23}
              e: {id: 'e', name: 'E', age: 24}
              f: @f = {id: 'f', name: 'F', age: 25}
              g: @newDoc = deepCopy origDoc
            @qnode.results @db, (err, found) =>
              @txn = createTxn 'set', 'users.g.age', 24
              transaction.applyTxn @txn, @db._data, memory
              @qnode.maybePublish @newDoc, origDoc, @txn, {@store, @pubSub}
              done(err)

          it 'should publish a "rmDoc" with the last doc of the old curr page', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('rmDoc', @qnode.channel, {ns: 'users', id: 'f', ver: transaction.getVer @txn})

          it 'should remove the last doc in the cache', ->
            expect(@qnode._cache).to.not.contain @f

          it 'should publish an "addDoc" with the altered doc', ->
            expect(@pubSub.publish).to.be.calledTwice()
            expect(@pubSub.publish).to.be.calledWith publishArgs('addDoc', @qnode.channel, {ns: 'users', doc: @newDoc, ver: transaction.getVer @txn})
          it 'should insert the altered doc into the cache', ->
            expect(@qnode._cache).to.contain @newDoc

  # maybePublish(newDoc, oldDoc, txn, services, cb)
    # for page 2 (and beyond by induction)
      # modifying a doc and it still satisfies the query
        describe 'if doc movement occurs in later pages', ->
          beforeEach (done) ->
            origDoc = id: 'g', name: 'G', age: 26
            @db._data.world.users =
              a: {id: 'a', name: 'A', age: 20}
              b: {id: 'b', name: 'B', age: 21}
              c: {id: 'c', name: 'C', age: 22}
              d: @d = {id: 'd', name: 'D', age: 23}
              e: @e = {id: 'e', name: 'E', age: 24}
              f: @f = {id: 'f', name: 'F', age: 25}
              g: newDoc = deepCopy origDoc
              h: {id: 'h', name: 'H', age: 27}
            @qnode.results @db, (err, found) =>
              txn = createTxn 'set', 'users.g.age', 28
              transaction.applyTxn txn, @db._data, memory
              @qnode.maybePublish newDoc, origDoc, txn, {@store, @pubSub}
              done(err)

          it 'should publish nothing', ->
            expect(@pubSub.publish).to.have.callCount(0)

          it 'should not alter the page results cache', ->
            expect(@qnode._cache).to.eql [@d, @e, @f]